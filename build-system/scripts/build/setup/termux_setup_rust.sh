# shellcheck shell=bash disable=SC1091 disable=SC2086 disable=SC2155
termux_setup_rust() {
	if [[ "${TERMUX_ON_DEVICE_BUILD}" == "true" ]]; then
		if [[ -z "$(command -v rustc)" ]]; then
			cat <<- EOL
			Package 'rust' is not installed.
			You can install it with

			pkg install rust

			pacman -S rust
			EOL
			exit 1
		fi
		local RUSTC_VERSION=$(rustc --version | awk '{ print $2 }')
		if [[ -n "${TERMUX_RUST_VERSION-}" && "${TERMUX_RUST_VERSION-}" != "${RUSTC_VERSION}" ]]; then
			cat <<- EOL >&2
			WARN: On device build with old rust version is not possible!
			TERMUX_RUST_VERSION = ${TERMUX_RUST_VERSION}
			RUSTC_VERSION       = ${RUSTC_VERSION}
			EOL
		fi
		return
	fi

	if [[ -z "${TERMUX_RUST_VERSION-}" ]]; then
		# Legacy compatibility: extract version with grep instead of sourcing
		# (old commits may not have packages/rust/build.sh, or have executable code)
		TERMUX_RUST_VERSION="$(grep -oP '^TERMUX_PKG_VERSION=\K.+' \
			"${TERMUX_SCRIPTDIR}/packages/rust/build.sh" 2>/dev/null | head -1 \
			| tr -d '"' | tr -d "'" | tr -d ' ' || true)"
		# Fallback to a stable toolchain if unavailable
		TERMUX_RUST_VERSION="${TERMUX_RUST_VERSION:-1.31.0}"
	fi
	# Legacy compatibility: normalize Debian-style dist versions (rust 1.90.0+really1.90.0,
	# bat@2f2adec, run CI 31429289079) so rustup only sees official toolchain names.
	# The '+really...' suffix is a packaging trick and the REAL toolchain is the part
	# AFTER '+really' (upstream srcurl uses ${TERMUX_PKG_VERSION##*y}, e.g. the temporary
	# pin range f9df163fe2..77810a1e1a ships '1.90.0+really1.89.0' but installs 1.89.0).
	TERMUX_RUST_VERSION="${TERMUX_RUST_VERSION##*+really}"
	if [[ "${TERMUX_RUST_VERSION}" == *"~beta"* ]]; then
		TERMUX_RUST_VERSION="beta"
	fi

	curl https://sh.rustup.rs -sSfo "${TERMUX_PKG_TMPDIR}"/rustup.sh
	sh "${TERMUX_PKG_TMPDIR}"/rustup.sh -y --default-toolchain "${TERMUX_RUST_VERSION}"

	export PATH="${HOME}/.cargo/bin:${PATH}"

	if [[ -n "${CARGO_TARGET_NAME-}" ]]; then
		# Specific version toolchain
		rustup target add "${CARGO_TARGET_NAME}" --toolchain "${TERMUX_RUST_VERSION}"
		# Default / Stable / rust-toolchain.toml toolchain
		rustup target add "${CARGO_TARGET_NAME}"
	fi
}
