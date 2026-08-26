# Description

On macOS 27.0 developer beta (26A5388g), pcbnew aborts when opening item
properties dialogs. Not every time, but several times a day during normal
editing. Seen with both 10.0.4 and 10.0.5, three times from Graphic Item
Properties and once from Footprint Properties. All four crash logs have the
same signature: AppKit throws an NSException inside
`-[NSWindow addChildWindow:ordered:]`, and since nothing on the C++ side can
catch it, the process terminates.

    libc++abi.dylib           __cxa_rethrow
    libobjc.A.dylib           objc_exception_rethrow
    AppKit                    NSPerformVisuallyAtomicChange
    AppKit                    -[NSWindow addChildWindow:ordered:]
    libkicommon.10.0.5.dylib  DIALOG_SHIM::ShowQuasiModal()
    _pcbnew.kiface            PCB_BASE_EDIT_FRAME::ShowGraphicItemPropertiesDialog(PCB_SHAPE*)
    _pcbnew.kiface            EDIT_TOOL::Properties(TOOL_EVENT const&)

The call comes from `KIPLATFORM::UI::ReparentWindow()` in
`libs/kiplatform/port/wxosx/ui.mm` (added in 3ad92bc8 to keep quasi-modal
dialogs above their parent), which calls `addChildWindow:ordered:` without an
exception guard.

The underlying throw looks like a macOS 27 beta regression in AppKit's window
ordering path rather than a KiCad bug (Apple Feedback FB23642313 reports the
same exception family killing other apps during order-on-screen), but wrapping
the call in `@try/@catch` would keep KiCad alive when it happens, at worst with
wrong dialog z-order:

    if( parentWindow && theWindow )
    {
        @try
        {
            [parentWindow addChildWindow:theWindow ordered:NSWindowAbove];
        }
        @catch( NSException* exc )
        {
        }
    }

Crash log attached. I have three more identical ones if useful.

# Steps to reproduce

1. macOS 27.0 developer beta (26A5388g)
2. Open any board in pcbnew
3. Select a graphic shape or footprint, press E
4. Intermittently, KiCad aborts instead of showing the dialog

# KiCad Version

[paste Help → About KiCad → Copy Version Info here]





On macOS 27.0 beta (26A5388g), -[NSWindow addChildWindow:ordered:] sometimes
throws an NSException from inside NSPerformVisuallyAtomicChange when a dialog
window is attached as a child of its parent frame. In a C++ app (KiCad 10.0.5,
wxWidgets-based) nothing can catch it, so the exception reaches
std::terminate and the process aborts.

Steps to reproduce:
1. Run KiCad 10.0.5 on 26A5388g
2. Open a board in the PCB editor, select an item, press E to open its
   properties dialog
3. Intermittently the app aborts (SIGABRT) instead of showing the dialog

Expected: addChildWindow:ordered: attaches the child window, as on macOS 26
and earlier.

Actual: NSException thrown during the window ordering pass; four identical
crash logs attached, spanning KiCad 10.0.4 and 10.0.5, so it's not tied to
one app version.

This looks like the same regression as FB23642313 (NSRemoteView
containingWindowWillOrderOnScreen assertion during order-on-screen), just
surfacing through the child-window path instead of makeKeyAndOrderFront.