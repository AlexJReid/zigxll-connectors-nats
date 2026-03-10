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

#include "../natsp.h"

#include <process.h>

#include "../mem.h"
#include "../glib/glib.h"

static BOOL CALLBACK
_initHandleFunction(PINIT_ONCE InitOnce, PVOID Parameter, PVOID *lpContext)
{
    natsInitOnceCb cb = (natsInitOnceCb) Parameter;

    (*cb)();

	return TRUE;
}

// InitOnceExecuteOnce can hang in DLLs that lack a proper DllMain
// (e.g. XLLs cross-compiled with Zig). Use a simple InterlockedCompareExchange
// guard instead — safe because nats_Open is only called from one thread at a time.
static volatile LONG gInitOnceFlag = 0; // 0=not done, 1=running, 2=done

bool
nats_InitOnce(natsInitOnceType *control, natsInitOnceCb cb)
{
    (void)control; // bypass INIT_ONCE entirely

    OutputDebugStringA("[nats.c] nats_InitOnce: entering (InterlockedCmpXchg path)\n");

    LONG prev = InterlockedCompareExchange(&gInitOnceFlag, 1, 0);
    if (prev == 2)
    {
        // Already initialised
        OutputDebugStringA("[nats.c] nats_InitOnce: already done\n");
        return true;
    }
    if (prev == 1)
    {
        // Another thread is initialising — spin (shouldn't happen for us)
        OutputDebugStringA("[nats.c] nats_InitOnce: waiting for other thread\n");
        while (InterlockedCompareExchange(&gInitOnceFlag, 1, 1) == 1)
            Sleep(1);
        return (gInitOnceFlag == 2);
    }

    // prev == 0: we are the initialiser
    OutputDebugStringA("[nats.c] nats_InitOnce: running callback\n");
    cb();
    InterlockedExchange(&gInitOnceFlag, 2);
    OutputDebugStringA("[nats.c] nats_InitOnce: callback done, flag set to 2\n");
    return true;
}

struct threadCtx
{
    natsThreadCb    entry;
    void            *arg;
};

static unsigned __stdcall _threadStart(void* arg)
{
  struct threadCtx *c = (struct threadCtx*) arg;

  OutputDebugStringA("[nats.c] _threadStart: thread entered\n");

  nats_setNATSThreadKey();

  OutputDebugStringA("[nats.c] _threadStart: calling entry function\n");
  c->entry(c->arg);

  OutputDebugStringA("[nats.c] _threadStart: entry function returned\n");
  NATS_FREE(c);

  nats_ReleaseThreadMemory();
  natsLib_Release();

  OutputDebugStringA("[nats.c] _threadStart: thread exiting\n");
  return 0;
}

natsStatus
natsThread_Create(natsThread **thread, natsThreadCb cb, void *arg)
{
    struct threadCtx    *ctx = NULL;
    natsThread          *t   = NULL;
    natsStatus          s    = NATS_OK;

    OutputDebugStringA("[nats.c] natsThread_Create: entering\n");
    natsLib_Retain();
    ctx = (struct threadCtx*) NATS_CALLOC(1, sizeof(*ctx));
    t = (natsThread*) NATS_CALLOC(1, sizeof(natsThread));

    if ((ctx == NULL) || (t == NULL))
        s = nats_setDefaultError(NATS_NO_MEMORY);

    if (s == NATS_OK)
    {
        ctx->entry  = cb;
        ctx->arg    = arg;

        OutputDebugStringA("[nats.c] natsThread_Create: calling _beginthreadex\n");
        t->t = (HANDLE) _beginthreadex(NULL, 0, _threadStart, ctx, 0, NULL);
        if (t->t == NULL)
        {
            char dbgbuf[128];
            DWORD err = GetLastError();
            wsprintfA(dbgbuf, "[nats.c] natsThread_Create: _beginthreadex FAILED, error=%lu\n", err);
            OutputDebugStringA(dbgbuf);
            s = nats_setError(NATS_SYS_ERROR,
                              "_beginthreadex error: %d",
                              err);
        }
        else
        {
            t->id = GetThreadId(t->t);
            OutputDebugStringA("[nats.c] natsThread_Create: thread created OK\n");
        }
    }
    if (s == NATS_OK)
    {
        *thread = t;
    }
    else
    {
        NATS_FREE(ctx);
        NATS_FREE(t);
        natsLib_Release();
    }

    OutputDebugStringA("[nats.c] natsThread_Create: returning\n");
    return s;
}

void
natsThread_Join(natsThread *t)
{
    if (GetCurrentThreadId() != t->id)
    {
        if (WaitForSingleObject(t->t, INFINITE))
            abort();
    }
}

void
natsThread_Detach(natsThread *t)
{
    // nothing for now.
}

bool
natsThread_IsCurrent(natsThread *t)
{
    if (GetCurrentThreadId() == t->id)
        return true;

    return false;
}

void
natsThread_Yield()
{
    // The correct way would be to call the following function.
    // However, it looks like the connection reconnect test
    // is failing on Windows without a proper sleep (that is,
    // even Sleep(0) does not help).
//    SwitchToThread();
    nats_Sleep(1);
}

void
natsThread_Destroy(natsThread *t)
{
    if (t == NULL)
        return;

    CloseHandle(t->t);

    NATS_FREE(t);
}

natsStatus
natsThreadLocal_CreateKey(natsThreadLocal *tl, void (*destructor)(void*))
{
    if ((*tl = TlsAlloc()) == TLS_OUT_OF_INDEXES)
    {
        return nats_setError(NATS_SYS_ERROR,
                             "TlsAlloc error: %d",
                              GetLastError());
    }

    return NATS_OK;
}

void*
natsThreadLocal_Get(natsThreadLocal tl)
{
    return (void*) TlsGetValue(tl);
}

natsStatus
natsThreadLocal_SetEx(natsThreadLocal tl, const void *value, bool setErr)
{
    if (TlsSetValue(tl, (LPVOID) value) == 0)
    {
        if (setErr)
            return nats_setError(NATS_SYS_ERROR,
                                 "TlsSetValue error: %d",
                                 GetLastError());
        else
            return NATS_SYS_ERROR;
    }

    return NATS_OK;
}

void
natsThreadLocal_DestroyKey(natsThreadLocal tl)
{
    TlsFree(tl);
}

