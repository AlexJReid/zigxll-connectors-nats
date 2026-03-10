// Copyright 2015-2024 The NATS Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <stddef.h>

#include "glibp.h"

#include "../util.h"
#include "../crypto.h"

#ifdef _WIN32
#include <windows.h>
#define NATS_DBG(msg) OutputDebugStringA("[nats.c] " msg "\n")
#else
#define NATS_DBG(msg) ((void)0)
#endif

int64_t gLockSpinCount = 2000;

static natsInitOnceType gInitOnce = NATS_ONCE_STATIC_INIT;
static natsLib gLib;

natsLib* nats_lib(void)
{
    return &gLib;
}

static void _freeLib(void);
static void _finalCleanup(void);

void natsLib_Retain(void)
{
    natsMutex_Lock(gLib.lock);

    gLib.refs++;

    natsMutex_Unlock(gLib.lock);
}

void natsLib_Release(void)
{
    int refs = 0;

    natsMutex_Lock(gLib.lock);

    refs = --(gLib.refs);

    natsMutex_Unlock(gLib.lock);

    if (refs == 0)
        _freeLib();
}

static void
_finalCleanup(void)
{
    natsThreadLocal_DestroyKey(gLib.errTLKey);
    natsThreadLocal_DestroyKey(gLib.natsThreadKey);
    natsMutex_Destroy(gLib.lock);
    gLib.lock = NULL;
}

static void
natsLib_Destructor(void)
{
    int refs = 0;

    if (!(gLib.wasOpenedOnce))
        return;

    // Destroy thread locals for the current thread.
    nats_ReleaseThreadMemory();

    // Do the final cleanup if possible
    natsMutex_Lock(gLib.lock);
    refs = gLib.refs;
    if (refs > 0)
    {
        // If some thread is still around when the process exits and has a
        // reference to the library, then don't do the final cleanup now.
        // If the process has not fully exited when the lib's last reference
        // is decremented, the final cleanup will be executed from that thread.
        gLib.finalCleanup = true;
    }
    natsMutex_Unlock(gLib.lock);

    if (refs != 0)
        return;

    _finalCleanup();
}

static void
_freeLib(void)
{
    const unsigned int offset = (unsigned int)offsetof(natsLib, refs);
    bool callFinalCleanup = false;

    nats_freeTimers(&gLib);
    nats_freeAsyncCbs(&gLib);
    nats_freeGC(&gLib);

    nats_freeDispatcherPool(&gLib.messageDispatchers);
    nats_freeDispatcherPool(&gLib.replyDispatchers);

    natsNUID_free();

    natsCondition_Destroy(gLib.cond);

    memset((void *)(offset + (char *)&gLib), 0, sizeof(natsLib) - offset);

    natsMutex_Lock(gLib.lock);
    callFinalCleanup = gLib.finalCleanup;
    if (gLib.closeCompleteCond != NULL)
    {
        if (gLib.closeCompleteSignal)
        {
            *gLib.closeCompleteBool = true;
            natsCondition_Signal(gLib.closeCompleteCond);
        }
        gLib.closeCompleteCond = NULL;
        gLib.closeCompleteBool = NULL;
        gLib.closeCompleteSignal = false;
    }
    gLib.closed = false;
    gLib.initialized = false;
    gLib.finalCleanup = false;
    natsMutex_Unlock(gLib.lock);

    if (callFinalCleanup)
        _finalCleanup();
}

static void
_destroyErrTL(void *localStorage)
{
    natsTLError *err = (natsTLError *)localStorage;
    NATS_FREE(err);
}

static void
_doInitOnce(void)
{
    natsStatus s;

    NATS_DBG("_doInitOnce: entering");
    memset(&gLib, 0, sizeof(natsLib));

    NATS_DBG("_doInitOnce: creating mutex");
    s = natsMutex_Create(&(gLib.lock));
    if (s == NATS_OK)
    {
        NATS_DBG("_doInitOnce: creating errTLKey");
        s = natsThreadLocal_CreateKey(&(gLib.errTLKey), _destroyErrTL);
    }
    if (s == NATS_OK)
    {
        NATS_DBG("_doInitOnce: creating natsThreadKey");
        s = natsThreadLocal_CreateKey(&(gLib.natsThreadKey), NULL);
    }
    if (s != NATS_OK)
    {
        NATS_DBG("_doInitOnce: FATAL - init failed, aborting");
        fprintf(stderr, "FATAL ERROR: Unable to initialize library!\n");
        fflush(stderr);
        abort();
    }

    NATS_DBG("_doInitOnce: calling nats_initForOS");
    nats_initForOS();
    NATS_DBG("_doInitOnce: nats_initForOS done");

    // atexit() can deadlock in DLLs where the CRT isn't fully bootstrapped
    // (e.g. XLLs built with Zig). Skip it — cleanup is handled explicitly
    // via nats_Close() / onTerminate() instead.
    // atexit(natsLib_Destructor);
    NATS_DBG("_doInitOnce: done (atexit skipped)");
}


static void
_libTearDown(void)
{
    nats_waitForDispatcherPoolShutdown(&gLib.messageDispatchers);
    nats_waitForDispatcherPoolShutdown(&gLib.replyDispatchers);

    if (gLib.timers.thread != NULL)
        natsThread_Join(gLib.timers.thread);

    if (gLib.asyncCbs.thread != NULL)
        natsThread_Join(gLib.asyncCbs.thread);

    if (gLib.gc.thread != NULL)
        natsThread_Join(gLib.gc.thread);

    natsLib_Release();
}

// environment variables will override the default options.
natsStatus
nats_openLib(natsClientConfig *config)
{
    natsStatus s = NATS_OK;

    natsClientConfig defaultConfig = {
        .LockSpinCount = -1,
        .ThreadPoolMax = 1,
    };
    if (config == NULL)
        config = &defaultConfig;

    NATS_DBG("nats_openLib: calling InitOnce");
    if (!nats_InitOnce(&gInitOnce, _doInitOnce))
    {
        NATS_DBG("nats_openLib: InitOnce FAILED");
        return NATS_FAILED_TO_INITIALIZE;
    }
    NATS_DBG("nats_openLib: InitOnce done, locking gLib.lock");

    natsMutex_Lock(gLib.lock);

    if (gLib.closed || gLib.initialized || gLib.initializing)
    {
        if (gLib.closed)
            s = NATS_FAILED_TO_INITIALIZE;
        else if (gLib.initializing)
            s = NATS_ILLEGAL_STATE;

        NATS_DBG("nats_openLib: already closed/initialized/initializing, returning");
        natsMutex_Unlock(gLib.lock);
        return s;
    }

    gLib.initializing = true;
    gLib.initAborted = false;

#if !defined(_WIN32)
    signal(SIGPIPE, SIG_IGN);
#endif

    srand((unsigned int)nats_NowInNanoSeconds());

    gLib.refs = 1;

    // If the caller specifies negative value, then we use the default
    if (config->LockSpinCount >= 0)
        gLockSpinCount = config->LockSpinCount;

    gLib.config = *config;
    NATS_DBG("nats_openLib: calling nats_Base32_Init");
    nats_Base32_Init();

    NATS_DBG("nats_openLib: creating condition var");
    s = natsCondition_Create(&(gLib.cond));

    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: calling natsCrypto_Init");
        s = natsCrypto_Init();
        NATS_DBG("nats_openLib: natsCrypto_Init done");
    }

    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: creating timer mutex");
        s = natsMutex_Create(&(gLib.timers.lock));
    }
    if (s == NATS_OK)
        s = natsCondition_Create(&(gLib.timers.cond));
    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: creating timer thread");
        s = natsThread_Create(&(gLib.timers.thread), nats_timerThreadf, &gLib);
        if (s == NATS_OK)
        {
            NATS_DBG("nats_openLib: timer thread created OK");
            gLib.refs++;
        }
        else
            NATS_DBG("nats_openLib: timer thread FAILED");
    }

    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: creating asyncCbs mutex");
        s = natsMutex_Create(&(gLib.asyncCbs.lock));
    }
    if (s == NATS_OK)
        s = natsCondition_Create(&(gLib.asyncCbs.cond));
    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: creating asyncCbs thread");
        s = natsThread_Create(&(gLib.asyncCbs.thread), nats_asyncCbsThreadf, &gLib);
        if (s == NATS_OK)
        {
            NATS_DBG("nats_openLib: asyncCbs thread created OK");
            gLib.refs++;
        }
        else
            NATS_DBG("nats_openLib: asyncCbs thread FAILED");
    }
    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: creating gc mutex");
        s = natsMutex_Create(&(gLib.gc.lock));
    }
    if (s == NATS_OK)
        s = natsCondition_Create(&(gLib.gc.cond));
    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: creating gc thread");
        s = natsThread_Create(&(gLib.gc.thread), nats_garbageCollectorThreadf, &gLib);
        if (s == NATS_OK)
        {
            NATS_DBG("nats_openLib: gc thread created OK");
            gLib.refs++;
        }
        else
            NATS_DBG("nats_openLib: gc thread FAILED");
    }
    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: calling natsNUID_init");
        s = natsNUID_init();
    }

    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: init messageDispatchers pool");
        s = nats_initDispatcherPool(&(gLib.messageDispatchers), config->ThreadPoolMax);
    }
    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: init replyDispatchers pool");
        s = nats_initDispatcherPool(&(gLib.replyDispatchers), config->ReplyThreadPoolMax);
    }

    if (s == NATS_OK)
    {
        NATS_DBG("nats_openLib: setting initialized=true");
        gLib.initialized = true;
    }

    // In case of success or error, broadcast so that lib's threads
    // can proceed.
    if (gLib.cond != NULL)
    {
        if (s != NATS_OK)
        {
            NATS_DBG("nats_openLib: init failed, setting shutdown flags");
            gLib.initAborted = true;
            gLib.timers.shutdown = true;
            gLib.asyncCbs.shutdown = true;
            gLib.gc.shutdown = true;
        }
        NATS_DBG("nats_openLib: broadcasting cond");
        natsCondition_Broadcast(gLib.cond);
    }

    gLib.initializing = false;
    gLib.wasOpenedOnce = true;

    NATS_DBG("nats_openLib: unlocking gLib.lock");
    natsMutex_Unlock(gLib.lock);

    if (s != NATS_OK)
    {
        NATS_DBG("nats_openLib: calling _libTearDown");
        _libTearDown();
    }

    NATS_DBG("nats_openLib: returning");
    return s;
}

natsStatus
nats_closeLib(bool wait, int64_t timeout)
{
    natsStatus s = NATS_OK;
    natsCondition *cond = NULL;
    bool complete = false;
    // int             i;

    // This is to protect against a call to nats_Close() while there
    // was no prior call to nats_Open(), either directly or indirectly.
    if (!nats_InitOnce(&gInitOnce, _doInitOnce))
        return NATS_ERR;

    natsMutex_Lock(gLib.lock);

    if (gLib.closed || !gLib.initialized)
    {
        bool closed = gLib.closed;

        natsMutex_Unlock(gLib.lock);

        if (closed)
            return NATS_ILLEGAL_STATE;
        return NATS_NOT_INITIALIZED;
    }
    if (wait)
    {
        if (natsThreadLocal_Get(gLib.natsThreadKey) != NULL)
            s = NATS_ILLEGAL_STATE;
        if (s == NATS_OK)
            s = natsCondition_Create(&cond);
        if (s != NATS_OK)
        {
            natsMutex_Unlock(gLib.lock);
            return s;
        }
        gLib.closeCompleteCond = cond;
        gLib.closeCompleteBool = &complete;
        gLib.closeCompleteSignal = true;
    }

    gLib.closed = true;

    natsMutex_Lock(gLib.timers.lock);
    gLib.timers.shutdown = true;
    natsCondition_Signal(gLib.timers.cond);
    natsMutex_Unlock(gLib.timers.lock);

    natsMutex_Lock(gLib.asyncCbs.lock);
    gLib.asyncCbs.shutdown = true;
    natsCondition_Signal(gLib.asyncCbs.cond);
    natsMutex_Unlock(gLib.asyncCbs.lock);

    natsMutex_Lock(gLib.gc.lock);
    gLib.gc.shutdown = true;
    natsCondition_Signal(gLib.gc.cond);
    natsMutex_Unlock(gLib.gc.lock);

    natsMutex_Unlock(gLib.lock);

    nats_signalDispatcherPoolToShutdown(&gLib.messageDispatchers);
    nats_signalDispatcherPoolToShutdown(&gLib.replyDispatchers);

    nats_ReleaseThreadMemory();
    _libTearDown();

    if (wait)
    {
        natsMutex_Lock(gLib.lock);
        while ((s != NATS_TIMEOUT) && !complete)
        {
            if (timeout <= 0)
                natsCondition_Wait(cond, gLib.lock);
            else
                s = natsCondition_TimedWait(cond, gLib.lock, timeout);
        }
        if (s != NATS_OK)
            gLib.closeCompleteSignal = false;
        natsMutex_Unlock(gLib.lock);

        natsCondition_Destroy(cond);
    }

    return s;
}

void nats_setNATSThreadKey(void)
{
    natsThreadLocal_Set(gLib.natsThreadKey, (const void *)1);
}

void nats_ReleaseThreadMemory(void)
{
    void *tl = NULL;

    if (!(gLib.wasOpenedOnce))
        return;

    tl = natsThreadLocal_Get(gLib.errTLKey);
    if (tl != NULL)
    {
        _destroyErrTL(tl);
        natsThreadLocal_SetEx(gLib.errTLKey, NULL, false);
    }
}

natsClientConfig *nats_testInspectClientConfig(void)
{
    // Immutable after startup
    return &gLib.config;
}

void nats_overrideDefaultOptionsWithConfig(natsOptions *opts)
{
    opts->writeDeadline = gLib.config.DefaultWriteDeadline;
    opts->useSharedDispatcher = gLib.config.DefaultToThreadPool;
    opts->useSharedReplyDispatcher = gLib.config.DefaultRepliesToThreadPool;
}
