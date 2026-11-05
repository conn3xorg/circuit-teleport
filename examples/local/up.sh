#!/usr/bin/env sh
# Starts two throwaway hosts that Conn3x can configure: a Teleport server on
# 127.0.0.1:$PORT (default 2222) and a node on 127.0.0.1:$NODE_PORT (default
# PORT + 1), on a Podman network of their own so the node can reach the
# server by name. Makes a fresh SSH key, puts both host keys in ./known_hosts,
# and stands in for your own CA: a throwaway CA in ./ca.crt and a certificate
# for the server's name, copied into the server at /etc/teleport-tls.
# CONTAINERFILE picks another image, such as one of Conn3x's test images.
# Needs Podman, since the hosts run systemd, and openssl.
# Rootful Podman is simplest: CONTAINER_CONNECTION=podman-machine-default-root
# on a Mac, or PODMAN="sudo podman" on Linux.
set -eu
cd "$(dirname "$0")"
port=${PORT:-2222}
node_port=${NODE_PORT:-$((port + 1))}
containerfile=${CONTAINERFILE:-Containerfile}
name=${CONTAINER_NAME:-circuit-teleport}

podman=${PODMAN:-podman}
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "$name" -f id_ed25519
if [ ! -f tls.crt ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 \
    -subj "/CN=$name example CA" -keyout ca.key -out ca.crt 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=$name" -keyout tls.key -out tls.csr 2>/dev/null
  printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' "$name" > tls.ext
  openssl x509 -req -days 7 -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -extfile tls.ext -out tls.crt 2>/dev/null
fi

$podman build -q -f "$containerfile" -t "$name" "$(dirname "$containerfile")" >/dev/null
$podman rm -f -v "$name" "$name-node" >/dev/null 2>&1 || true
$podman network exists "$name" || $podman network create "$name" >/dev/null
$podman run -d --name "$name" --network "$name" --systemd=always --privileged \
  -p "127.0.0.1:$port:22" "$name" >/dev/null
$podman run -d --name "$name-node" --network "$name" --systemd=always --privileged \
  -p "127.0.0.1:$node_port:22" "$name" >/dev/null
for c in "$name" "$name-node"; do
  $podman exec -i "$c" sh -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' < id_ed25519.pub
done
$podman exec "$name" mkdir -p -m 700 /etc/teleport-tls
$podman cp tls.crt "$name:/etc/teleport-tls/tls.crt"
$podman cp tls.key "$name:/etc/teleport-tls/tls.key"
for c in "$name" "$name-node"; do
  $podman exec "$c" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true
done

: > known_hosts
for p in "$port" "$node_port"; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ssh-keyscan -p "$p" 127.0.0.1 > known_hosts.part 2>/dev/null && [ -s known_hosts.part ]; then
      cat known_hosts.part >> known_hosts
      break
    fi
    sleep 1
  done
  if [ ! -s known_hosts.part ]; then
    rm -f known_hosts.part
    echo "The containers started, but SSH didn't answer on 127.0.0.1:$p." >&2
    exit 1
  fi
  rm -f known_hosts.part
done
echo "Ready on 127.0.0.1:$port and 127.0.0.1:$node_port. Now run: conn3x init && conn3x apply -var port=$port -var node_port=$node_port -var server_name=$name"
