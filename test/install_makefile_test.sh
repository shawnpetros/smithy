#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${ROOT}/.tmp"
TMPDIR="$(mktemp -d "${ROOT}/.tmp/install-test.XXXXXX")"
FAKE_BIN="${TMPDIR}/fake-bin"
PREFIX="${TMPDIR}/prefix"
MISE_LOG="${TMPDIR}/mise.log"

cleanup() {
  for built_bin in "${ROOT}/wrapper/bin/smithy" "${ROOT}/elixir/bin/symphony"; do
    if [ -f "${built_bin}" ] && grep -q "fake binary from install_makefile_test" "${built_bin}"; then
      rm -f "${built_bin}"
    fi
  done

  rm -rf "${TMPDIR}"
}

trap cleanup EXIT

mkdir -p "${FAKE_BIN}" "${PREFIX}/bin"

cat > "${FAKE_BIN}/mise" <<'MISE'
#!/usr/bin/env bash
set -euo pipefail

: "${MISE_FAKE_LOG:?}"
printf '%s|%s\n' "${PWD}" "$*" >> "${MISE_FAKE_LOG}"

case "${1:-}" in
  trust)
    exit 0
    ;;
  exec)
    shift
    if [ "${1:-}" = "--" ]; then
      shift
    fi

    if [ "${MISE_FAKE_FAIL_RUNTIME:-0}" = "1" ] && [ "${1:-}" != "mix" ]; then
      echo "runtime missing" >&2
      exit 127
    fi

    case "${1:-}" in
      elixir)
        echo "Elixir 1.19.0"
        exit 0
        ;;
      erl)
        exit 0
        ;;
      mix)
        shift
        case "${1:-}" in
          deps.get)
            exit 0
            ;;
          escript.build)
            mkdir -p bin
            case "$(basename "${PWD}")" in
              wrapper)
                printf '#!/usr/bin/env sh\n# fake binary from install_makefile_test\necho smithy fake\n' > bin/smithy
                chmod +x bin/smithy
                ;;
              elixir)
                printf '#!/usr/bin/env sh\n# fake binary from install_makefile_test\necho symphony fake\n' > bin/symphony
                chmod +x bin/symphony
                ;;
              *)
                echo "unexpected project directory: ${PWD}" >&2
                exit 64
                ;;
            esac
            ;;
          test)
            exit 0
            ;;
          *)
            echo "unexpected mix command: $*" >&2
            exit 64
            ;;
        esac
        ;;
      *)
        echo "unexpected mise exec command: $*" >&2
        exit 64
        ;;
    esac
    ;;
  *)
    echo "unexpected mise command: $*" >&2
    exit 64
    ;;
esac
MISE

chmod +x "${FAKE_BIN}/mise"
touch "${MISE_LOG}"

export MISE_FAKE_LOG="${MISE_LOG}"
export PATH="${PREFIX}/bin:${FAKE_BIN}:/usr/bin:/bin:/usr/sbin:/sbin"

INSTALL_OUTPUT="${TMPDIR}/install.out"
make -C "${ROOT}" install PREFIX="${PREFIX}" MISE=mise >"${INSTALL_OUTPUT}"

test "$(which smithy)" = "${PREFIX}/bin/smithy"
test "$(which symphony)" = "${PREFIX}/bin/symphony"
test "$(readlink "${PREFIX}/bin/smithy")" = "${ROOT}/wrapper/bin/smithy"
test "$(readlink "${PREFIX}/bin/symphony")" = "${ROOT}/elixir/bin/symphony"
grep -q "${ROOT}/wrapper|trust" "${MISE_LOG}"
grep -q "${ROOT}/elixir|trust" "${MISE_LOG}"
grep -q "${ROOT}/wrapper|exec -- mix deps.get" "${MISE_LOG}"
grep -q "${ROOT}/elixir|exec -- mix deps.get" "${MISE_LOG}"
grep -q "${ROOT}/wrapper|exec -- mix escript.build" "${MISE_LOG}"
grep -q "${ROOT}/elixir|exec -- mix escript.build" "${MISE_LOG}"
grep -q "Smithy installed. Next:" "${INSTALL_OUTPUT}"
grep -q "smithy daemon start <slug>" "${INSTALL_OUTPUT}"

make -C "${ROOT}" install PREFIX="${PREFIX}" MISE=mise >/dev/null
make -C "${ROOT}" uninstall PREFIX="${PREFIX}" >/dev/null
make -C "${ROOT}" uninstall PREFIX="${PREFIX}" >/dev/null
test ! -e "${PREFIX}/bin/smithy"
test ! -e "${PREFIX}/bin/symphony"

: > "${MISE_LOG}"
make -C "${ROOT}" rebuild MISE=mise >/dev/null
grep -q "exec -- mix escript.build" "${MISE_LOG}"
if grep -q "deps.get" "${MISE_LOG}"; then
  echo "make rebuild must not run deps.get" >&2
  exit 1
fi

set +e
MISSING_MISE_OUTPUT="$(make -C "${ROOT}" install PREFIX="${PREFIX}" MISE=missing-mise 2>&1)"
MISSING_MISE_STATUS=$?
set -e
test "${MISSING_MISE_STATUS}" -ne 0
printf '%s\n' "${MISSING_MISE_OUTPUT}" | grep -q "mise is required"
printf '%s\n' "${MISSING_MISE_OUTPUT}" | grep -q "https://mise.jdx.dev"

set +e
MISSING_RUNTIME_OUTPUT="$(MISE_FAKE_FAIL_RUNTIME=1 make -C "${ROOT}" install PREFIX="${PREFIX}" MISE=mise 2>&1)"
MISSING_RUNTIME_STATUS=$?
set -e
test "${MISSING_RUNTIME_STATUS}" -ne 0
printf '%s\n' "${MISSING_RUNTIME_OUTPUT}" | grep -q "Erlang/Elixir runtimes are not available"
printf '%s\n' "${MISSING_RUNTIME_OUTPUT}" | grep -q "mise install"
