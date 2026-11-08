local parser = require('minifugit.ui.diff.parser')

---@param text string
---@return table<integer, MiniFugitDiffLine>
local function by_text(lines)
    local parsed = parser.parse_lines(lines)
    local indexed = {}

    for _, line in ipairs(parsed) do
        indexed[line.raw_row] = line
    end

    return indexed
end

describe('minifugit diff parser', function()
    it('parses unified hunk headers', function()
        local old_start, old_count, new_start, new_count =
            parser.parse_hunk_header('@@ -3,2 +3,4 @@ context')

        assert.are.same(
            { 3, 2, 3, 4 },
            { old_start, old_count, new_start, new_count }
        )
    end)

    it('parses combined hunk headers as first parent plus result', function()
        local old_start, old_count, new_start, new_count =
            parser.parse_hunk_header('@@@ -8,5 -8,5 +12,9 @@@ l12')

        assert.are.same(
            { 8, 5, 12, 9 },
            { old_start, old_count, new_start, new_count }
        )
    end)

    it('turns combined rows into sided lines with worktree numbers', function()
        local lines = {
            'diff --cc a.txt',
            'index 269cbf3,dd65621..0000000',
            '--- a/a.txt',
            '+++ b/a.txt',
            '@@@ -1,5 -1,5 +1,9 @@@',
            '  l1',
            '++<<<<<<< HEAD',
            ' +ours',
            '++=======',
            '+ theirs',
            '++>>>>>>> feature',
        }
        local indexed = by_text(lines)

        assert.are.same({
            kind = 'hunk',
            old_number = 1,
            new_number = 1,
            raw_row = 5,
            text = '@@@ -1,5 -1,5 +1,9 @@@',
        }, indexed[5])

        assert.are.same({
            kind = 'context',
            old_number = 1,
            new_number = 1,
            prefix_width = 2,
            raw_row = 6,
            text = '  l1',
        }, indexed[6])

        -- Present in neither parent: a conflict marker, never a plain addition.
        assert.are.same({
            kind = 'conflict_marker',
            old_number = nil,
            new_number = 2,
            prefix_width = 2,
            raw_row = 7,
            text = '++<<<<<<< HEAD',
        }, indexed[7])

        -- Present only in the first parent (HEAD).
        assert.are.same({
            kind = 'conflict_head',
            old_number = 2,
            new_number = 3,
            prefix_width = 2,
            raw_row = 8,
            text = ' +ours',
        }, indexed[8])

        -- Present only in the second parent (the incoming side).
        assert.are.same({
            kind = 'conflict_incoming',
            old_number = nil,
            new_number = 5,
            prefix_width = 2,
            raw_row = 10,
            text = '+ theirs',
        }, indexed[10])
    end)

    it('finds one hunk per combined hunk header', function()
        local hunks = parser.parse_hunks({
            '@@@ -1,5 -1,5 +1,9 @@@',
            '  l1',
            '@@@ -8,5 -8,5 +12,9 @@@ l12',
            '  l8',
        })

        assert.are.equal(2, #hunks)
        assert.are.same({ 1, 5, 12, 9 }, {
            hunks[1].old_start,
            hunks[1].old_count,
            hunks[2].new_start,
            hunks[2].new_count,
        })
    end)

    it('keeps an unmerged path report as a header', function()
        local line = by_text({ '* Unmerged path a.txt' })[1]

        assert.are.same('header', line.kind)
        assert.are.equal('* Unmerged path a.txt', line.text)
    end)

    it('keeps lines removed from a parent out of the result', function()
        -- Partially resolved conflict: both parents still hold `z`, the
        -- worktree deleted it, so Git removes it once per parent.
        local lines = {
            '@@@ -1,3 -1,3 +1,6 @@@',
            '  a',
            '++<<<<<<< HEAD',
            ' +ours',
            '- z',
            '++=======',
            '+ theirs',
            ' -z',
            '++>>>>>>> feature',
        }
        local parsed = parser.parse_lines(lines)
        local expected = {
            { 'context', 1, 1 },
            { 'conflict_marker', nil, 2 },
            { 'conflict_head', 2, 3 },
            { 'conflict_head_removed', 3, nil },
            { 'conflict_marker', nil, 4 },
            { 'conflict_incoming', nil, 5 },
            { 'conflict_incoming_removed', nil, nil },
            { 'conflict_marker', nil, 6 },
        }

        for index, row in ipairs(expected) do
            -- Row 1 is the hunk header.
            local line = parsed[index + 1]

            assert.are.same(
                row,
                { line.kind, line.old_number, line.new_number },
                'row ' .. index
            )
        end
    end)
end)
