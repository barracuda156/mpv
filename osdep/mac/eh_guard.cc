/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

// C++ exceptions must never unwind past a Cocoa main-thread callback on
// 10.5/10.6 PPC: _Unwind_* resolves to the system libunwind in libSystem,
// whose ppc unwinder cannot walk Apple's own unwind-info-free libdispatch
// and AppKit frames. Phase-1 handler lookup then either misses every
// handler below the dispatch machinery (std::terminate) or crashes in
// unw_get_proc_info (observed: SIGBUS at 0x24 when a C++ dependency threw
// on the main thread under [NSApp run] during network streaming). Catching
// at the dispatch boundary keeps throw->catch within GCC-compiled frames,
// which that unwinder handles correctly.

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <typeinfo>
#include <cxxabi.h>

extern "C" void mp_mac_guard(void (*fn)(void *ctx), void *ctx);

static void report(const char *what)
{
    const std::type_info *t = abi::__cxa_current_exception_type();
    const char *name = t ? t->name() : "<unknown>";
    int status = -1;
    char *demangled = t ? abi::__cxa_demangle(name, nullptr, nullptr, &status)
                        : nullptr;
    fprintf(stderr,
            "mpv: caught C++ exception '%s'%s%s%s on the Cocoa main thread; "
            "suppressed: propagating would crash in the system unwinder\n",
            (status == 0 && demangled) ? demangled : name,
            what ? " (" : "", what ? what : "", what ? ")" : "");
    free(demangled);
}

extern "C" void mp_mac_guard(void (*fn)(void *ctx), void *ctx)
{
    try {
        fn(ctx);
    } catch (const std::exception &e) {
        report(e.what());
    } catch (...) {
        report(nullptr);
    }
}
