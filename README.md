# Augment Vim & Neovim Plugin for Emacs lsp-mode

This is an attempt to adapt the lsp-server from
[Augment](https://augmentcode.com)'s Vim plugin to work in emacs with
[lsp-mode](https://emacs-lsp.github.io/lsp-mode/)

## Current status

What's working:

1. Augment log in and status

1. Chat, including multi-turn and referring to a region of code

1. Completions with company-mode (but see the commit "Rewrite
   completion responses from Augment so Emacs accepts them")

## Getting Started

1. Sign up for a free trial of Augment at
   [augmentcode.com](https://augmentcode.com).

1. Install [Node.js](https://nodejs.org/en/download/package-manager/all),
   version 22.0.0 or newer, which is a required dependency.

1. Add this to your `init.el`:

```emacs-lisp
(use-package lsp-augment
  :after (lsp-mode markdown-mode)
  :vc (:fetcher github :repo "dotemacs/augment.vim" :rev "dotemacs-fork")
  :config
  (setq lsp-augment-server-script (thread-last
                                    "lsp-augment"
                                    locate-library
                                    file-name-directory
                                    (expand-file-name "dist/server.js")))
  (dolist (modes-for-augment '((go-mode . "augment")
                               (emacs-lisp-mode . "augment")
                               (lua-mode . "augment")))
    (add-to-list 'lsp-language-id-configuration modes-for-augment)
  ;; optional, should you wish to add extra directories
  ;; to add more context for Augment Code
  (setq lsp-augment-additional-context-folders
          '("~/projects/shared-library"
           "~/projects/core-framework\"))))
```

The above snippet will git clone the repo and set up the correct load path.

Feel free to add more modes to `modes-for-augment` which you use and
have LSP servers for.

1. Start emacs and log into your Augment account via `M-x lsp-augment-signin`

## Basic Usage

Use `M-x lsp-augment-signin` to log in and `M-x lsp-augment-signout`
to log out. You can check the status including the progress of
workspace sync with `M-x lsp-augment-status`.

## Chat

Use `M-x lsp-augment-chat` to chat with Augment; you will be prompted
to enter your chat message. If the region is active then the selected
text will be passed to Augment as part of the chat. The chat history
is kept in a `*Augment Chat History*` buffer and will be used for
multi-turn conversations.

To clear the history and start a new conversion, use the function `M-x lsp-augment-reset-chat`.

## Licensing and Distribution

This repository includes two main components:

1. **Vim Plugin:** This includes all files in the repository except `dist` folder. These files are licensed under the [MIT License](LICENSE.md#vim-plugin).
2. **Emacs Lisp Client:** This is licensed under the same [MIT License](LICENSE.md#vim-plugin).
1. **Server (`dist` folder):** This file is proprietary and licensed under a [Custom Proprietary License](LICENSE.md#server).

For details on usage restrictions, refer to the [LICENSE.md](LICENSE.md) file.
