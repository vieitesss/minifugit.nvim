# Diff preview reuses and restores the status target window

We decided diff previews open into the **target window**: a normal edit window
selected by the status UI, or a preview split anchored to the status window when
no edit window is available. Previews own a save/restore invariant for that window:
before swapping in a plugin-owned diff buffer we capture the window's previous
buffer, its window-local options, and whether we created the window
(`{prev_buf, prev_winopts, created}`). On close we restore the captured buffer
and options, or close the window if we created it. Stacked↔split layout
transitions hand this invariant from the outgoing window to the incoming one
rather than re-capturing, so the user's original (non-preview) buffer is never
lost across a toggle.

The tradeoff is that the preview subsystem carries an explicit per-window
lifecycle (capture, transition handoff, self-rollback on a failed buffer swap)
instead of opening throwaway windows and discarding them. We accepted that cost
because reusing the target window keeps the layout stable and lets the user
return to exactly the buffer and window options they had before previewing —
including resetting preview-only options such as `scrollbind`/`cursorbind` —
which dedicated throwaway windows could not guarantee without the same
bookkeeping. The invariant has a single writer and is read only on restore, so
the surprising part (why a saved-buffer invariant exists at all) is recorded
here rather than rediscovered from the code.
