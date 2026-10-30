.PHONY: build drafts test clean

build:
	s build.stk

drafts:
	s build.stk --drafts

test:
	s test t/

# Generated output is committed (GitHub Pages serves docs/); `clean`
# removes it so the next `make build` regenerates from scratch.
clean:
	rm -rf docs
