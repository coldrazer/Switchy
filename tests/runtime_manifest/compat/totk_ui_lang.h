/* Off macOS the real header (CoreFoundation locale lookup) is not available; the harness only needs English. */
#pragma once
#define TOTK_UI(zh, en) (en)
