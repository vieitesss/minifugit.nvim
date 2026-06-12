local word_diff = require('minifugit.ui.diff.word_diff')

describe('minifugit.ui.diff.word_diff', function()
    it('highlights only changed words on replacement', function()
        local right = word_diff.changed_ranges(
            'status = "todo",',
            'status = "done",',
            'right'
        )
        local left = word_diff.changed_ranges(
            'status = "todo",',
            'status = "done",',
            'left'
        )

        assert.are.same({ { start_col = 10, end_col = 14 } }, right)
        assert.are.same({ { start_col = 10, end_col = 14 } }, left)
    end)

    it(
        'highlights inserted words without expanding to the whole line',
        function()
            local ranges = word_diff.changed_ranges(
                'local value = 1',
                'local new_value = 1',
                'right'
            )

            assert.are.same({ { start_col = 6, end_col = 15 } }, ranges)
        end
    )

    it(
        'highlights removed words without expanding to the whole line',
        function()
            local ranges = word_diff.changed_ranges(
                'local old_value = 1',
                'local value = 1',
                'left'
            )

            assert.are.same({ { start_col = 6, end_col = 15 } }, ranges)
        end
    )
end)
