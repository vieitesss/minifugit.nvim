# Use native plugin-owned buffers

We decided minifugit buffers are normal text buffers owned by the plugin: create them with `nvim_create_buf()`, set only buffer-local options on the created buffer, publish a plugin filetype late, and use buffer-local mappings/actions. This follows `:h lua-plugin`, especially `lua-plugin-filetype`, `lua-plugin-config`, and `lua-plugin-ui`.

The main tradeoff is that we keep a small buffer helper instead of hiding buffers behind a UI abstraction. That makes buffer ownership and option scope explicit, avoids accidental global option writes, and keeps diff previews in plugin-owned buffers so target windows can be restored without inheriting preview-only options such as `scrollbind` or `cursorbind`.
