# Lessons

## Testing workflow
- Always use the **simulator** for testing. Only deploy to device when explicitly asked.

## ghostty_surface_binding_action
- The third parameter is the **byte length of the action string**, not a magic number. Always use `UInt(action.utf8.count)` — never hardcode the length. A wrong length causes silent parse failure on the Zig side.
