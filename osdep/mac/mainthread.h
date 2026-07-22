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

#pragma once

#include <stdbool.h>

// Run fn(ctx) on the Cocoa main thread without using Apple blocks (which
// FSF GCC cannot compile). With sync=true this blocks until fn has run;
// when already called on the main thread, fn runs directly. With sync=false
// it returns immediately; ctx must then stay valid until fn has run.
//
// 10.6+ builds (MAC_OS_X_VERSION_MIN_REQUIRED >= 1060) use libdispatch's
// function-pointer API; 10.5 builds fall back to
// -performSelectorOnMainThread:, since 10.5 has no libdispatch at all.
void mp_mac_run_on_main(void (*fn)(void *ctx), void *ctx, bool sync);
