#!/bin/bash

# Installs kubeconform, yq and gitleaks at the versions pinned in config.env.
# Every download is checked against the pinned SHA-256 before it is installed.
#
# Installs to ~/.local/bin by default. Override with INSTALL_DIR=/some/path.
# Linux amd64 only.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$INSTALL_DIR"

# Download a file and stop if its SHA-256 does not match the pinned value.
# Usage: download_and_verify <url> <expected_sha256> <output_file>
download_and_verify() {
    local url="$1"
    local expected_sha256="$2"
    local output_file="$3"
    local actual_sha256

    curl --fail --silent --show-error --location "$url" --output "$output_file"

    actual_sha256="$(sha256sum "$output_file" | cut -d' ' -f1)"
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo -e "${RED}Checksum mismatch for $url${NC}"
        echo "  expected: $expected_sha256"
        echo "  actual:   $actual_sha256"
        exit 1
    fi
}

# Download a .tar.gz, verify it, and copy one binary from it into INSTALL_DIR.
# Usage: install_from_tarball <name> <url> <expected_sha256>
install_from_tarball() {
    local name="$1"
    local url="$2"
    local expected_sha256="$3"
    local tarball="$WORK_DIR/$name.tar.gz"
    local extract_dir="$WORK_DIR/$name"

    download_and_verify "$url" "$expected_sha256" "$tarball"

    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    install -m 755 "$extract_dir/$name" "$INSTALL_DIR/$name"
}

echo -e "${CYAN}Installing tools to $INSTALL_DIR${NC}"

install_from_tarball kubeconform \
    "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    "$KUBECONFORM_SHA256"
echo -e "  ${GREEN}✓ kubeconform ${KUBECONFORM_VERSION}${NC}"

install_from_tarball gitleaks \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    "$GITLEAKS_SHA256"
echo -e "  ${GREEN}✓ gitleaks ${GITLEAKS_VERSION}${NC}"

# yq is a single binary, not a tarball.
download_and_verify \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    "$YQ_SHA256" \
    "$WORK_DIR/yq"
install -m 755 "$WORK_DIR/yq" "$INSTALL_DIR/yq"
echo -e "  ${GREEN}✓ yq ${YQ_VERSION}${NC}"

# Tell the user if the install folder is not on their PATH.
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) echo -e "${CYAN}Add $INSTALL_DIR to your PATH to use these tools.${NC}" ;;
esac
