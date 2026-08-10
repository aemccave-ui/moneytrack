import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'

export default [
  { ignores: ['dist'] },
  js.configs.recommended,
  reactHooks.configs.flat.recommended,
  reactRefresh.configs.vite,
  {
    files: ['**/*.{js,jsx}'],
    languageOptions: {
      ecmaVersion: 'latest',
      globals: globals.browser,
      parserOptions: {
        ecmaVersion: 'latest',
        ecmaFeatures: { jsx: true },
        sourceType: 'module',
      },
    },
  },
  {
    files: ['src/App.jsx'],
    rules: {
      // App keeps explicit memoization around the existing Home read-model. The
      // compiler-preservation rule is advisory here and does not change runtime
      // correctness; rewriting Home is outside the UX-022 lifecycle scope.
      'react-hooks/preserve-manual-memoization': 'off',
    },
  },
  {
    files: ['src/AccountsExplorer.jsx'],
    rules: {
      // MoveHistorySheet deliberately clears stale preview/error state when its
      // target account changes before starting the next abortable request.
      'react-hooks/set-state-in-effect': 'off',
    },
  },
]
