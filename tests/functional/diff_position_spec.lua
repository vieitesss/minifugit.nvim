---@diagnostic disable: undefined-field
local parser = require('minifugit.ui.diff.parser')
local position = require('minifugit.ui.diff.position')

---Partially resolved conflict: both parents still hold `z`, the worktree
---deleted it, so Git removes it once per parent.
---@type string[]
local combined_diff = {
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

describe('minifugit.ui.diff.position', function()
    describe(
        'minifugit.ui.diff.position.source_line_for_stacked_row',
        function()
            it('lands on the worktree line of every surviving row', function()
                local hunks = parser.parse_hunks(combined_diff)
                local expected = {
                    [2] = 1,
                    [3] = 2,
                    [4] = 3,
                    [6] = 4,
                    [7] = 5,
                    [9] = 6,
                }

                for raw_row, line_number in pairs(expected) do
                    assert.are.equal(
                        line_number,
                        position.source_line_for_stacked_row(
                            combined_diff,
                            hunks,
                            raw_row
                        ),
                        'raw row ' .. raw_row
                    )
                end
            end)

            it(
                'falls back to the next worktree line for removed rows',
                function()
                    local hunks = parser.parse_hunks(combined_diff)

                    -- Removed parents hold no worktree line; the cursor goes to the
                    -- nearest surviving row instead of the start of the file.
                    assert.are.equal(
                        4,
                        position.source_line_for_stacked_row(
                            combined_diff,
                            hunks,
                            5
                        )
                    )
                    assert.are.equal(
                        6,
                        position.source_line_for_stacked_row(
                            combined_diff,
                            hunks,
                            8
                        )
                    )
                end
            )
        end
    )
end)
