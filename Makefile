HOST := chaufr
BIN := /opt/smtpd/bin/smtpd
EXE := _build/default/bin/smtpd.exe
RELEASE := _build/smtpd.release

.DEFAULT_GOAL := help

help:
	@echo "ocaml-smtpd (server-build): Chaufr's mail server"
	@echo ""
	@echo "  make build      build for development"
	@echo "  make test       run the tests"
	@echo "  make release    build, strip and size the release binary"
	@echo "  make check      check the release binary can run on the server"
	@echo "  make deploy     test, release, check, then install on the server"
	@echo "  make rollback   go back to the binary before the last deploy"
	@echo "  make status     whether smtpd runs, and its memory"
	@echo "  make logs       the last lines of smtpd's log"

build:
	@dune build

test:
	@dune test --force

release:
	@dune build --profile release @install
	@strip -o $(RELEASE) $(EXE)
	@echo "built $(RELEASE) ($$(du -h $(RELEASE) | cut -f1))"

check: release
	@need=$$(objdump -T $(EXE) | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1) && \
	have=GLIBC_$$(ssh $(HOST) 'ldd --version | head -1 | grep -o "[0-9.]*$$"') && \
	echo "glibc: the binary needs $$need, the server has $$have" && \
	test "$$(printf '%s\n%s\n' "$$need" "$$have" | sort -V | tail -1)" = "$$have"
	@ssh $(HOST) /sbin/ldconfig -p > _build/server-libraries.txt && \
	for lib in $$(ldd $(EXE) | awk '/=>/ {print $$1}'); do \
	  grep -q "^[[:space:]]$$lib " _build/server-libraries.txt || { echo "missing on the server: $$lib"; exit 1; }; \
	done && echo "libraries: all present on the server"

deploy:
	@test "$$(git rev-parse --abbrev-ref HEAD)" = server-build || { echo "deploy from server-build"; exit 1; }
	@git diff --quiet HEAD || { echo "commit your changes first"; exit 1; }
	@$(MAKE) --no-print-directory test check
	@rsync -az $(RELEASE) $(HOST):smtpd.new
	@ssh -t $(HOST) 'sudo cp -p $(BIN) $(BIN).previous && sudo install -m 755 ~/smtpd.new $(BIN) && sudo systemctl restart smtpd && sleep 2 && systemctl is-active smtpd && printf "QUIT\r\n" | nc -q 2 127.0.0.1 2525 | head -1'
	@echo "deployed $$(git rev-parse --short HEAD); make rollback restores the previous binary"

rollback:
	@ssh -t $(HOST) 'sudo mv $(BIN).previous $(BIN) && sudo systemctl restart smtpd && sleep 2 && systemctl is-active smtpd'

status:
	@ssh $(HOST) 'systemctl is-active smtpd && systemctl show smtpd -p MemoryCurrent -p MemoryPeak && ps -o rss=,etime= -C smtpd'

logs:
	@ssh -t $(HOST) 'sudo journalctl -u smtpd -n 30 --no-pager'

.PHONY: help build test release check deploy rollback status logs
