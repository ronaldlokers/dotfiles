# Arch, matching the Omarchy host: same package manager, same rolling
# versions, and the same troubleshooting either side of the container
# boundary. It also carries libatomic.so.1, which debian:trixie does not —
# mise's prebuilt node links against it, so on Debian `mise install` failed
# and took gemini-cli and the whole chezmoi apply down with it.
FROM archlinux:base

# mise is here rather than as a devcontainer feature for two reasons. The
# feature (devcontainers-extra) resolves jdx/mise's latest release and
# currently 404s on a non-release tag upstream. And postCreateCommand runs
# before DevPod clones the dotfiles, so the pinned ~/.local/bin/mise this
# repo installs does not exist yet when post-create.sh needs it. Interactive
# shells still get the pinned one: dot_zshrc prefers it explicitly.
#
# openssh is required, not optional: Arch's git only optdepends on it, but
# DevPod clones this repo over SSH inside the container, git commit signing
# (dot_config/git/config.tmpl) shells out to ssh-keygen, and the ssh-agent
# liveness check in dot_config/shell/ssh-agent.sh needs `ssh` to exist to
# tell a dead agent from a missing binary.
#
# base-devel and python are required too — mise's prebuilt binaries are not
# enough. gemini-cli pulls node-pty, which ships no prebuilt binary for this
# platform and compiles through node-gyp at install time; node-gyp needs
# make/gcc (base-devel) and a python interpreter. python is listed here
# explicitly rather than left to mise, because mise installing it as part of
# the same batch as gemini-cli is an ordering race, not a guarantee.
RUN pacman -Syu --noconfirm --needed \
      git zsh sudo curl ca-certificates which less mise \
      openssh base-devel python \
 && pacman -Scc --noconfirm

# dot_zshrc exports LANG=en_US.UTF-8. Arch ships only C/C.utf8/POSIX, so
# without this every shell in the container prints "Cannot set LC_CTYPE to
# default locale". Debian's common-utils feature was doing this silently;
# on Arch it is ours to do.
RUN sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen

# What the common-utils feature used to set up. It refuses to run on Arch
# (it accepts debian, rhel and alpine only), so the user, the sudoers entry
# and the login shell are created here instead. UID/GID 1000 matches the
# usual host user; devcontainer.json's updateRemoteUserUID fixes up the
# case where the host user is not 1000.
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "$USER_GID" "$USERNAME" \
 && useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /usr/bin/zsh "$USERNAME" \
 && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME" \
 && chmod 0440 /etc/sudoers.d/"$USERNAME"

USER $USERNAME

# common-utils appended a PATH entry for ~/.local/bin to /etc/bash.bashrc and
# /etc/zsh/zshrc; nothing replaces that here, and Arch's own /etc/profile
# only adds /usr/local/bin. Without this, rtk (installed to
# ~/.local/bin, invoked by bare name from ~/.claude/hooks/rtk-rewrite.sh)
# and this repo's own repos-sync/devcontainer-init/dotfiles-update-check are
# unreachable by name. On the host this comes from omarchy-zsh's shared
# shell config instead (see dot_zshrc), which does not exist in a container.
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
