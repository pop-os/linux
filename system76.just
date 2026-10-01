# Example: just -f system76.just update 7.2.7
update version: remote-add
	git fetch ubuntu tag cod/mainline/v{{version}} --depth=100 --no-tags

remote-add:
	git remote add ubuntu https://git.launchpad.net/~ubuntu-kernel-test/ubuntu/+source/linux/+git/mainline-crack/ || echo true

