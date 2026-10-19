EMACS ?= emacs
ELISP = typemacs-session.el typemacs-eglot.el typemacs-preview.el typemacs-sync.el typemacs.el

.PHONY: check compile test integration

check: compile test

compile:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

test:
	$(EMACS) -Q --batch -L . -L test --eval '(setq load-prefer-newer t)' -l typemacs-test -f ert-run-tests-batch-and-exit

integration:
	$(EMACS) -Q --batch -L . -L test --eval '(setq load-prefer-newer t)' -l typemacs-integration-test -f ert-run-tests-batch-and-exit
