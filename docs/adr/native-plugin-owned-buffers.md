# Use native plugin-owned buffers

minifugit buffers are normal Neovim text buffers owned by the plugin, created with `nvim_create_buf()`, configured with buffer-local options, and given plugin filetypes late. This keeps ownership and option scope explicit, avoids accidental global option writes, and favors a small helper over a custom UI abstraction.
