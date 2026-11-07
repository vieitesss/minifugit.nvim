local parser = require('minifugit.ui.diff.parser')
local split_render = require('minifugit.ui.diff.split_render')

local GROUPS = {
    diff_added = 'MiniFugitDiffAdded',
    diff_removed = 'MiniFugitDiffRemoved',
    diff_added_intraline = 'MiniFugitDiffAddedIntraline',
    diff_removed_intraline = 'MiniFugitDiffRemovedIntraline',
}

---@param old_lines string[]
---@param new_lines string[]
---@param diff_lines string[]
---@return MiniFugitSplitRenderPlan
local function render(old_lines, new_lines, diff_lines)
    return split_render.render(
        { left = { lines = old_lines }, right = { lines = new_lines } },
        diff_lines,
        parser.parse_hunks(diff_lines),
        GROUPS
    )
end

describe('minifugit.ui.diff.split_render', function()
    it(
        'fills the old side and highlights the added line of an insertion',
        function()
            local plan = render({ 'a', 'b' }, { 'a', 'x', 'b' }, {
                'diff --git a/file.txt b/file.txt',
                'index 1111111..2222222 100644',
                '--- a/file.txt',
                '+++ b/file.txt',
                '@@ -1,2 +1,3 @@',
                ' a',
                '+x',
                ' b',
            })

            assert.are.same({ 'a', '', 'b' }, plan.left.lines)
            assert.are.same({ 'a', 'x', 'b' }, plan.right.lines)
            assert.are.same({
                {
                    kind = 'context',
                    old_lnum = 1,
                    new_lnum = 1,
                    hunk_index = 1,
                },
                { kind = 'filler', hunk_index = 1 },
                {
                    kind = 'context',
                    old_lnum = 2,
                    new_lnum = 3,
                    hunk_index = 1,
                },
            }, plan.left.rows)
            assert.are.same({
                {
                    kind = 'context',
                    old_lnum = 1,
                    new_lnum = 1,
                    hunk_index = 1,
                },
                { kind = 'add', new_lnum = 2, hunk_index = 1 },
                {
                    kind = 'context',
                    old_lnum = 2,
                    new_lnum = 3,
                    hunk_index = 1,
                },
            }, plan.right.rows)
            assert.are.same({}, plan.left.backgrounds)
            assert.are.same({}, plan.left.intraline)
            assert.are.same({
                {
                    row = 1,
                    col = 0,
                    opts = {
                        end_row = 1,
                        end_col = 1,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffAdded',
                        priority = 200,
                    },
                },
            }, plan.right.backgrounds)
            assert.are.same({}, plan.right.intraline)
            assert.are.same({ [1] = 2 }, plan.anchors)
        end
    )

    it(
        'fills the new side and highlights the removed line of a deletion',
        function()
            local plan = render({ 'keep', 'gone' }, { 'keep' }, {
                '@@ -1,2 +1,1 @@',
                ' keep',
                '-gone',
            })

            assert.are.same({ 'keep', 'gone' }, plan.left.lines)
            assert.are.same({ 'keep', '' }, plan.right.lines)
            assert.are.same({
                {
                    kind = 'context',
                    old_lnum = 1,
                    new_lnum = 1,
                    hunk_index = 1,
                },
                { kind = 'delete', old_lnum = 2, hunk_index = 1 },
            }, plan.left.rows)
            assert.are.same({
                {
                    kind = 'context',
                    old_lnum = 1,
                    new_lnum = 1,
                    hunk_index = 1,
                },
                { kind = 'filler', hunk_index = 1 },
            }, plan.right.rows)
            assert.are.same({
                {
                    row = 1,
                    col = 0,
                    opts = {
                        end_row = 1,
                        end_col = 4,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffRemoved',
                        priority = 200,
                    },
                },
            }, plan.left.backgrounds)
            assert.are.same({}, plan.left.intraline)
            assert.are.same({}, plan.right.backgrounds)
            assert.are.same({}, plan.right.intraline)
            assert.are.same({ [1] = 2 }, plan.anchors)
        end
    )

    it('describes the changed word bytes of a replaced line', function()
        local plan = render({ 'hello world' }, { 'hello there' }, {
            '@@ -1 +1 @@',
            '-hello world',
            '+hello there',
        })

        assert.are.same({ 'hello world' }, plan.left.lines)
        assert.are.same({ 'hello there' }, plan.right.lines)
        assert.are.same({
            { kind = 'delete', old_lnum = 1, hunk_index = 1 },
        }, plan.left.rows)
        assert.are.same({
            { kind = 'add', new_lnum = 1, hunk_index = 1 },
        }, plan.right.rows)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_row = 0,
                    end_col = 11,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffRemoved',
                    priority = 200,
                },
            },
        }, plan.left.backgrounds)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_row = 0,
                    end_col = 11,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffAdded',
                    priority = 200,
                },
            },
        }, plan.right.backgrounds)
        assert.are.same({
            {
                row = 0,
                col = 6,
                opts = {
                    end_col = 11,
                    hl_group = 'MiniFugitDiffRemovedIntraline',
                    priority = 201,
                },
            },
        }, plan.left.intraline)
        assert.are.same({
            {
                row = 0,
                col = 6,
                opts = {
                    end_col = 11,
                    hl_group = 'MiniFugitDiffAddedIntraline',
                    priority = 201,
                },
            },
        }, plan.right.intraline)
        assert.are.same({ [1] = 1 }, plan.anchors)
    end)

    it(
        'aligns unequal runs with fillers and pairs changes across a hunk',
        function()
            local plan = render(
                { 'l1', 'l2', 'l4', 'l5' },
                { 'l1', 'N2', 'N3', 'l4', 'N5' },
                {
                    '@@ -1,4 +1,5 @@',
                    ' l1',
                    '-l2',
                    '+N2',
                    '+N3',
                    ' l4',
                    '-l5',
                    '+N5',
                }
            )

            assert.are.same({ 'l1', 'l2', '', 'l4', 'l5' }, plan.left.lines)
            assert.are.same({ 'l1', 'N2', 'N3', 'l4', 'N5' }, plan.right.lines)
            assert.are.same({
                {
                    kind = 'context',
                    old_lnum = 1,
                    new_lnum = 1,
                    hunk_index = 1,
                },
                { kind = 'delete', old_lnum = 2, hunk_index = 1 },
                { kind = 'filler', hunk_index = 1 },
                {
                    kind = 'context',
                    old_lnum = 3,
                    new_lnum = 4,
                    hunk_index = 1,
                },
                { kind = 'delete', old_lnum = 4, hunk_index = 1 },
            }, plan.left.rows)
            assert.are.same({
                {
                    kind = 'context',
                    old_lnum = 1,
                    new_lnum = 1,
                    hunk_index = 1,
                },
                { kind = 'add', new_lnum = 2, hunk_index = 1 },
                { kind = 'add', new_lnum = 3, hunk_index = 1 },
                {
                    kind = 'context',
                    old_lnum = 3,
                    new_lnum = 4,
                    hunk_index = 1,
                },
                { kind = 'add', new_lnum = 5, hunk_index = 1 },
            }, plan.right.rows)
            assert.are.same({ [1] = 2 }, plan.anchors)
            assert.are.same({
                {
                    row = 1,
                    col = 0,
                    opts = {
                        end_row = 1,
                        end_col = 2,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffRemoved',
                        priority = 200,
                    },
                },
                {
                    row = 4,
                    col = 0,
                    opts = {
                        end_row = 4,
                        end_col = 2,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffRemoved',
                        priority = 200,
                    },
                },
            }, plan.left.backgrounds)
            assert.are.same({
                {
                    row = 1,
                    col = 0,
                    opts = {
                        end_row = 1,
                        end_col = 2,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffAdded',
                        priority = 200,
                    },
                },
                {
                    row = 2,
                    col = 0,
                    opts = {
                        end_row = 2,
                        end_col = 2,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffAdded',
                        priority = 200,
                    },
                },
                {
                    row = 4,
                    col = 0,
                    opts = {
                        end_row = 4,
                        end_col = 2,
                        hl_eol = true,
                        hl_group = 'MiniFugitDiffAdded',
                        priority = 200,
                    },
                },
            }, plan.right.backgrounds)
            assert.are.same({
                {
                    row = 1,
                    col = 0,
                    opts = {
                        end_col = 2,
                        hl_group = 'MiniFugitDiffRemovedIntraline',
                        priority = 201,
                    },
                },
                {
                    row = 4,
                    col = 0,
                    opts = {
                        end_col = 2,
                        hl_group = 'MiniFugitDiffRemovedIntraline',
                        priority = 201,
                    },
                },
            }, plan.left.intraline)
            assert.are.same({
                {
                    row = 1,
                    col = 0,
                    opts = {
                        end_col = 2,
                        hl_group = 'MiniFugitDiffAddedIntraline',
                        priority = 201,
                    },
                },
                {
                    row = 2,
                    col = 0,
                    opts = {
                        end_col = 2,
                        hl_group = 'MiniFugitDiffAddedIntraline',
                        priority = 201,
                    },
                },
            }, plan.right.intraline)
        end
    )

    it('separates hunks and anchors each one at its first change', function()
        local plan = render(
            { 'a1', 'b2', 'c3', 'd4', 'e5', 'f6' },
            { 'A1', 'b2', 'c3', 'd4', 'e5', 'F6' },
            {
                'diff --git a/file.txt b/file.txt',
                '--- a/file.txt',
                '+++ b/file.txt',
                '@@ -1,2 +1,2 @@',
                '-a1',
                '+A1',
                ' b2',
                '@@ -5,2 +5,2 @@',
                ' e5',
                '-f6',
                '+F6',
            }
        )

        local separator = ('─'):rep(40)

        assert.are.same({ 'a1', 'b2', separator, 'e5', 'f6' }, plan.left.lines)
        assert.are.same({ 'A1', 'b2', separator, 'e5', 'F6' }, plan.right.lines)
        assert.are.same({
            { kind = 'delete', old_lnum = 1, hunk_index = 1 },
            { kind = 'context', old_lnum = 2, new_lnum = 2, hunk_index = 1 },
            { kind = 'separator', hunk_index = 2 },
            { kind = 'context', old_lnum = 5, new_lnum = 5, hunk_index = 2 },
            { kind = 'delete', old_lnum = 6, hunk_index = 2 },
        }, plan.left.rows)
        assert.are.same({
            { kind = 'add', new_lnum = 1, hunk_index = 1 },
            { kind = 'context', old_lnum = 2, new_lnum = 2, hunk_index = 1 },
            { kind = 'separator', hunk_index = 2 },
            { kind = 'context', old_lnum = 5, new_lnum = 5, hunk_index = 2 },
            { kind = 'add', new_lnum = 6, hunk_index = 2 },
        }, plan.right.rows)
        assert.are.same({ [1] = 1, [2] = 5 }, plan.anchors)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_row = 0,
                    end_col = 2,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffRemoved',
                    priority = 200,
                },
            },
            {
                row = 4,
                col = 0,
                opts = {
                    end_row = 4,
                    end_col = 2,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffRemoved',
                    priority = 200,
                },
            },
        }, plan.left.backgrounds)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_row = 0,
                    end_col = 2,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffAdded',
                    priority = 200,
                },
            },
            {
                row = 4,
                col = 0,
                opts = {
                    end_row = 4,
                    end_col = 2,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffAdded',
                    priority = 200,
                },
            },
        }, plan.right.backgrounds)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_col = 2,
                    hl_group = 'MiniFugitDiffRemovedIntraline',
                    priority = 201,
                },
            },
            {
                row = 4,
                col = 0,
                opts = {
                    end_col = 2,
                    hl_group = 'MiniFugitDiffRemovedIntraline',
                    priority = 201,
                },
            },
        }, plan.left.intraline)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_col = 2,
                    hl_group = 'MiniFugitDiffAddedIntraline',
                    priority = 201,
                },
            },
            {
                row = 4,
                col = 0,
                opts = {
                    end_col = 2,
                    hl_group = 'MiniFugitDiffAddedIntraline',
                    priority = 201,
                },
            },
        }, plan.right.intraline)
    end)

    it('omits file context outside the hunks', function()
        local plan = render({ 'pre1', 'pre2', 'x', 'post' }, {
            'pre1',
            'pre2',
            'y',
            'post',
        }, {
            '@@ -3 +3 @@',
            '-x',
            '+y',
        })

        assert.are.same({ 'x' }, plan.left.lines)
        assert.are.same({ 'y' }, plan.right.lines)
        assert.are.same({
            { kind = 'delete', old_lnum = 3, hunk_index = 1 },
        }, plan.left.rows)
        assert.are.same({
            { kind = 'add', new_lnum = 3, hunk_index = 1 },
        }, plan.right.rows)
        assert.are.same({ [1] = 1 }, plan.anchors)
    end)

    it('ignores no-final-newline markers when aligning lines', function()
        local plan = render({ 'old text' }, { 'new text' }, {
            '@@ -1 +1 @@',
            '-old text',
            '\\ No newline at end of file',
            '+new text',
            '\\ No newline at end of file',
        })

        assert.are.same({ 'old text' }, plan.left.lines)
        assert.are.same({ 'new text' }, plan.right.lines)
        assert.are.same({
            { kind = 'delete', old_lnum = 1, hunk_index = 1 },
        }, plan.left.rows)
        assert.are.same({
            { kind = 'add', new_lnum = 1, hunk_index = 1 },
        }, plan.right.rows)
        assert.are.same({ [1] = 1 }, plan.anchors)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_col = 3,
                    hl_group = 'MiniFugitDiffRemovedIntraline',
                    priority = 201,
                },
            },
        }, plan.left.intraline)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_col = 3,
                    hl_group = 'MiniFugitDiffAddedIntraline',
                    priority = 201,
                },
            },
        }, plan.right.intraline)
    end)

    it('returns an empty plan for a metadata-only patch', function()
        local plan = render({}, {}, {
            'diff --git a/a.bin b/a.bin',
            'index 1111111..2222222 100644',
            'Binary files a/a.bin and b/a.bin differ',
        })

        assert.are.same({
            left = {
                lines = {},
                rows = {},
                backgrounds = {},
                intraline = {},
            },
            right = {
                lines = {},
                rows = {},
                backgrounds = {},
                intraline = {},
            },
            anchors = {},
        }, plan)
    end)

    it('describes UTF-8 changes in byte columns', function()
        local plan = render({ 'héllo wörld' }, { 'héllo there' }, {
            '@@ -1 +1 @@',
            '-héllo wörld',
            '+héllo there',
        })

        assert.are.same({ 'héllo wörld' }, plan.left.lines)
        assert.are.same({ 'héllo there' }, plan.right.lines)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_row = 0,
                    end_col = 13,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffRemoved',
                    priority = 200,
                },
            },
        }, plan.left.backgrounds)
        assert.are.same({
            {
                row = 0,
                col = 0,
                opts = {
                    end_row = 0,
                    end_col = 12,
                    hl_eol = true,
                    hl_group = 'MiniFugitDiffAdded',
                    priority = 200,
                },
            },
        }, plan.right.backgrounds)
        assert.are.same({
            {
                row = 0,
                col = 7,
                opts = {
                    end_col = 13,
                    hl_group = 'MiniFugitDiffRemovedIntraline',
                    priority = 201,
                },
            },
        }, plan.left.intraline)
        assert.are.same({
            {
                row = 0,
                col = 7,
                opts = {
                    end_col = 12,
                    hl_group = 'MiniFugitDiffAddedIntraline',
                    priority = 201,
                },
            },
        }, plan.right.intraline)
    end)
end)
