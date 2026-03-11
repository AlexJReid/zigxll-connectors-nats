// Prevent the linker from pulling in msvcrt.lib, which conflicts with
// vcruntime (linked by ZigXLL). This happens when statically linking
// OpenSSL libs built against the legacy MSVC CRT.
#ifdef _MSC_VER
#pragma comment(linker, "/NODEFAULTLIB:msvcrt.lib")
#endif
