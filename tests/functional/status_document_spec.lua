local StatusDocument = require('minifugit.ui.status.document')

local GROUPS = {
    conflict = 'MiniFugitConflict',
    head = 'MiniFugitHead',
    ignored = 'MiniFugitIgnored',
    loading = 'MiniFugitLoading',
    staged = 'MiniFugitStage',
    unpushed = 'MiniFugitUnpushed',
    unstaged = 'MiniFugitUnstage',
    untracked = 'MiniFugitUntracked',
}

---@param overrides table?
---@return GitStatusSnapshot
local function snapshot(overrides)
    return vim.tbl_extend('force', {
        branch = 'main',
        root = '/repo',
        entries = {},
        unpushed_commits = {},
    }, overrides or {})
end

---@param overrides table?
---@param opts StatusDocumentOptions?
---@return StatusDocument
local function build(overrides, opts)
    return StatusDocument.new(snapshot(overrides), GROUPS, opts)
end

---@param entries GitStatusEntry[]
---@param opts StatusDocumentOptions?
---@return StatusDocument
local function document_of(entries, opts)
    return build({ entries = entries }, opts)
end

---@param staged string
---@param unstaged string
---@param path string
---@param orig_path string?
---@return GitStatusEntry
local function entry(staged, unstaged, path, orig_path)
    return {
        staged = staged,
        unstaged = unstaged,
        path = path,
        orig_path = orig_path,
    }
end

---@param hash string
---@param short_hash string
---@param message string
---@return GitCommit
local function commit(hash, short_hash, message)
    return { hash = hash, short_hash = short_hash, message = message }
end

---@param document StatusDocument
---@return string[]
local function texts(document)
    return vim.tbl_map(function(line)
        return line.text
    end, document.lines)
end

---@param document StatusDocument
---@param text string
---@return integer
local function row_of(document, text)
    for row, line in ipairs(document.lines) do
        if line.text == text then
            return row
        end
    end

    error('status document row not found: ' .. text)
end

---@param items GitStatusEntryItem[]
---@return string[]
local function item_keys(items)
    return vim.tbl_map(function(item)
        return item.key
    end, items)
end

---@param items GitStatusEntryItem[]
---@return string[]
local function sections(items)
    return vim.tbl_map(function(item)
        return item.section
    end, items)
end

---@return StatusDocument
local function mixed_document()
    return document_of({
        entry('M', 'M', 'both.txt'),
        entry(' ', 'M', 'unstaged.txt'),
        entry('M', ' ', 'staged.txt'),
        entry('?', '?', 'new.txt'),
    })
end

---@return StatusDocument
local function duplicate_document()
    return document_of({ entry('M', 'M', 'both.txt') })
end

describe('status document', function()
    describe('lines', function()
        it(
            'renders sections in status order with duplicates per section',
            function()
                assert.are.same({
                    'HEAD: main',
                    'Root: /repo',
                    '',
                    'Unstaged (2)',
                    'MM both.txt',
                    ' M unstaged.txt',
                    '',
                    'Staged (2)',
                    'MM both.txt',
                    'M  staged.txt',
                    '',
                    'Untracked (1)',
                    '?? new.txt',
                }, texts(mixed_document()))
            end
        )

        it('escapes display text but keeps raw paths', function()
            local lf = 'line\nbreak.txt'
            local crlf = 'line\r\nbreak.txt'
            local controls = 'tab\t.\1\127.txt'
            local document = document_of({
                entry('?', '?', lf),
                entry('?', '?', crlf),
                entry('?', '?', controls),
            })

            assert.are.same({
                'HEAD: main',
                'Root: /repo',
                '',
                'Untracked (3)',
                '?? line^@break.txt',
                '?? line^M^@break.txt',
                '?? tab^I.^A^?.txt',
            }, texts(document))

            local items = document:entries()
            assert.are.same(
                { lf, crlf, controls },
                vim.tbl_map(function(item)
                    return item.entry.path
                end, items)
            )
            assert.are.equal('untracked\0\0' .. lf, items[1].key)
            assert.are.equal('\0' .. crlf, document:capture(6).entry_key)
        end)
    end)

    describe('filter', function()
        it('filters by the escaped current path', function()
            local document = document_of({
                entry('?', '?', 'line\nbreak.txt'),
                entry('?', '?', 'ordinary.txt'),
            }, { filter = 'LINE^@' })

            assert.are.same({
                'HEAD: main',
                'Root: /repo',
                '',
                'filter=LINE^@',
                '',
                'Untracked (1)',
                '?? line^@break.txt',
            }, texts(document))
            assert.are.equal(
                'line\nbreak.txt',
                document:entries()[1].entry.path
            )
        end)

        it('filters by the escaped original path', function()
            local document = document_of({
                entry('R', ' ', 'renamed.txt', 'old\nname.txt'),
            }, { filter = 'old^@' })

            assert.are.same({
                'HEAD: main',
                'Root: /repo',
                '',
                'filter=old^@',
                '',
                'Staged (1)',
                'R  old^@name.txt -> renamed.txt',
            }, texts(document))
            assert.are.equal(
                'staged\0old\nname.txt\0renamed.txt',
                document:entries()[1].key
            )
        end)

        it('does not match raw control characters', function()
            local document = document_of({
                entry('?', '?', 'line\nbreak.txt'),
            }, { filter = 'line\nbreak.txt' })

            assert.are.same({}, document:entries())
            assert.is_true(
                vim.tbl_contains(texts(document), 'No entries match filter')
            )
        end)
    end)

    describe('output modes', function()
        it('renders an error document', function()
            local document = build({
                branch = '',
                root = '',
                error = 'Not a git repository',
            })

            assert.are.same({
                'HEAD: (none)',
                '',
                'Not a git repository',
            }, texts(document))
            assert.is_nil(document:resolve())
        end)

        it('renders base mode with base identities', function()
            local document = build({
                branch = '',
                entries = { entry('M', ' ', 'file.txt') },
            }, { base = 'abcdef1234567890' })

            assert.are.same({
                'Base: abcdef1 (read-only)',
                'Root: /repo',
                '',
                'Changes since abcdef1 (1)',
                'M  file.txt',
            }, texts(document))
            assert.are.equal('base', document:entries()[1].section)
            assert.are.equal('base\0\0file.txt', document:entries()[1].key)
        end)

        it('renders a clean base document', function()
            local document = build(
                { branch = '' },
                { base = 'abcdef1234567890' }
            )

            assert.are.same({
                'Base: abcdef1 (read-only)',
                'Root: /repo',
                '',
                'No changes since abcdef1',
            }, texts(document))
            assert.is_nil(document:resolve())
        end)

        it('renders a loading line above errors', function()
            local document = build({ error = 'boom' }, {
                loading_message = 'Fetching',
                loading_frame = '-',
            })

            assert.are.same({
                'HEAD: main',
                'Root: /repo',
                '- Fetching',
                '',
                'boom',
            }, texts(document))
        end)
    end)

    describe('entries', function()
        it('returns every visible entry item in row order', function()
            local items = mixed_document():entries()

            assert.are.same({
                'unstaged\0\0both.txt',
                'unstaged\0\0unstaged.txt',
                'staged\0\0both.txt',
                'staged\0\0staged.txt',
                'untracked\0\0new.txt',
            }, item_keys(items))
            assert.are.same({
                'unstaged',
                'unstaged',
                'staged',
                'staged',
                'untracked',
            }, sections(items))
        end)

        it('reads a reversed range the same as a forward one', function()
            local document = mixed_document()

            assert.are.same({
                'unstaged\0\0both.txt',
                'unstaged\0\0unstaged.txt',
                'staged\0\0both.txt',
                'staged\0\0staged.txt',
            }, item_keys(document:entries(10, 5)))
            assert.are.same(
                item_keys(document:entries(5, 10)),
                item_keys(document:entries(10, 5))
            )
        end)

        it('returns no items for header-only and empty ranges', function()
            local document = mixed_document()

            assert.are.same({}, document:entries(1, 4))
            assert.are.same({}, document:entries(0, 0))
            assert.are.same({}, document:entries(7, 7))
        end)
    end)

    describe('item', function()
        it('returns the entry under the row with its section', function()
            local document = mixed_document()
            local item = document:item(row_of(document, 'M  staged.txt'))

            assert.are.equal('entry', item.kind)
            assert.are.equal('staged', item.section)
            assert.are.equal('staged\0\0staged.txt', item.key)
            assert.are.equal('staged.txt', item.entry.path)
        end)

        it(
            'returns nil for headers, blank lines and mismatched kinds',
            function()
                local document = build({
                    entries = { entry('?', '?', 'new.txt') },
                    unpushed_commits = {
                        commit('a' .. ('1'):rep(39), 'a111111', 'one'),
                    },
                })

                assert.is_nil(document:item(row_of(document, 'HEAD: main')))
                assert.is_nil(document:item(row_of(document, 'Unpushed (1)')))
                assert.is_nil(
                    document:item(row_of(document, 'a111111 one'), 'entry')
                )
                assert.is_nil(document:item(1, 'commit'))
                assert.is_nil(
                    document:item(row_of(document, '?? new.txt'), 'commit')
                )
                assert.is_nil(document:item(nil))
                assert.are.equal(
                    'commit',
                    document:item(row_of(document, 'a111111 one')).kind
                )
            end
        )

        it('returns commits keyed by the full hash', function()
            local hash = 'abcdef0' .. ('2'):rep(33)
            local document = build({
                entries = { entry('?', '?', 'new.txt') },
                unpushed_commits = { commit(hash, 'abcdef0', 'one') },
            })

            local item = document:item(row_of(document, 'abcdef0 one'))

            assert.are.equal('commit', item.kind)
            assert.are.equal(hash, item.key)
            assert.are.equal('one', item.commit.message)
            assert.are.equal(1, #document:entries())
        end)

        it('prefers the item under the row over the previous state', function()
            local document = mixed_document()
            local state = document:capture(row_of(document, 'M  staged.txt'))
            local item = document:item(
                row_of(document, ' M unstaged.txt'),
                'entry',
                state
            )

            assert.are.equal('unstaged', item.section)
            assert.are.equal('unstaged.txt', item.entry.path)
        end)

        it('falls back to previous keys when the row holds no item', function()
            local document = duplicate_document()
            local item = document:item(7, 'entry', document:capture(8))

            assert.are.equal('staged', item.section)
            assert.are.equal('both.txt', item.entry.path)
        end)

        it('falls back to the previous commit key on header rows', function()
            local hash = 'abcdef0' .. ('3'):rep(33)
            local document = build({
                unpushed_commits = { commit(hash, 'abcdef0', 'one') },
            })
            local state = document:capture(row_of(document, 'abcdef0 one'))
            local item = document:item(1, 'commit', state)

            assert.are.equal(hash, item.key)
        end)
    end)

    describe('resolve', function()
        it('returns the exact item row of a captured state', function()
            local document = mixed_document()

            assert.are.equal(9, document:resolve(document:capture(9)))
            assert.are.equal(5, document:resolve(document:capture(5)))
        end)

        it('falls back to entry identity when the section changed', function()
            local state = duplicate_document():capture(5)
            local staged = document_of({ entry('M', ' ', 'both.txt') })

            assert.are.equal(5, staged:resolve(state))
        end)

        it('falls back to a commit key', function()
            local hash = 'abcdef0' .. ('5'):rep(33)
            local document = build({
                unpushed_commits = {
                    commit(hash, 'abcdef0', 'one'),
                    commit(hash .. 'b', 'abcdef0', 'two'),
                },
            })

            assert.are.equal(6, document:resolve({ commit_key = hash .. 'b' }))
            assert.are.equal(6, document:resolve(document:capture(6)))
        end)

        it('keeps the fallback row when following the entry is off', function()
            local document = mixed_document()

            assert.are.equal(
                7,
                document:resolve({ row = 7, follow_entry = false })
            )
            assert.are.equal(
                5,
                document:resolve({
                    item_key = 'staged\0\0staged.txt',
                    row = 5,
                    follow_entry = false,
                })
            )
            assert.are.equal(
                5,
                document:resolve({
                    entry_key = '\0both.txt',
                    follow_entry = false,
                })
            )
        end)

        it('skips a non-item row to the first entry', function()
            local document = document_of({ entry(' ', 'M', 'other.txt') })
            local stale = duplicate_document():capture(5)

            assert.are.equal(5, document:resolve({ row = 4 }))
            assert.are.equal(5, document:resolve(stale))
        end)

        it('clamps an old row inside the document', function()
            local document = document_of({ entry(' ', 'M', 'other.txt') })

            assert.are.equal(5, document:resolve({ row = 99 }))
            assert.are.equal(5, document:resolve({ row = -3 }))
        end)

        it('selects nothing when the document has no items', function()
            local document = build({})

            assert.are.same({
                'HEAD: main',
                'Root: /repo',
                '',
                'Working tree clean',
            }, texts(document))
            assert.is_nil(document:resolve())
            assert.is_nil(document:resolve({}))
            assert.are.equal(4, document:resolve({ row = 99 }))
            assert.is_nil(document:item(1))
            assert.are.same({}, document:entries())
        end)
    end)

    describe('capture', function()
        it('records entry identity separately from the section key', function()
            local document = duplicate_document()
            local unstaged = document:capture(5)
            local staged = document:capture(8)

            assert.are.equal('unstaged\0\0both.txt', unstaged.item_key)
            assert.are.equal('staged\0\0both.txt', staged.item_key)
            assert.are.equal(staged.entry_key, unstaged.entry_key)
            assert.are.equal('\0both.txt', staged.entry_key)
            assert.is_true(staged.follow_entry)
        end)

        it('records commit identity and keeps headers keyless', function()
            local hash = 'abcdef0' .. ('4'):rep(33)
            local document = build({
                unpushed_commits = { commit(hash, 'abcdef0', 'one') },
            })
            local commit_state =
                document:capture(row_of(document, 'abcdef0 one'))
            local header_state = document:capture(1)

            assert.are.equal(hash, commit_state.commit_key)
            assert.is_nil(commit_state.item_key)
            assert.is_nil(header_state.item_key)
            assert.is_nil(header_state.entry_key)
            assert.is_nil(header_state.commit_key)
        end)

        it('uses raw rename paths for keys', function()
            local document = document_of({
                entry('R', ' ', 'renamed.txt', 'old\nname.txt'),
            })
            local state = document:capture(
                row_of(document, 'R  old^@name.txt -> renamed.txt')
            )

            assert.are.equal(
                'staged\0old\nname.txt\0renamed.txt',
                state.item_key
            )
            assert.are.equal('old\nname.txt\0renamed.txt', state.entry_key)
        end)
    end)
end)
