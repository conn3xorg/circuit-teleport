# Local example

Applies circuit-teleport to two throwaway Rocky Linux 10 containers with systemd: a server running auth and proxy, and a node that joins it. You need Conn3x, Podman and openssl.

`up.sh` puts both containers on a Podman network of their own, so the node can reach the server by its container name. It also stands in for your own CA: it makes a throwaway one in `ca.crt`, signs a certificate for the server's name with it, and copies that into the server. The example passes `ca.crt` to both hosts as `proxy_ca`.

The containers run privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
export TF_VAR_join_token=$(openssl rand -hex 24)
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To reach the node through Teleport, make a user and a short-lived identity on the server, then use it:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 '
  export PATH=/usr/local/bin:$PATH
  tctl users add demo --roles=access --logins=root >/dev/null
  tctl auth sign --user=demo --ttl=1h --out=/root/demo-identity --overwrite
  tsh -i /root/demo-identity --proxy=circuit-teleport:443 ssh root@node1 uptime'
```

The server listens on `127.0.0.1:2222` and the node on `127.0.0.1:2223`. Set `PORT` and `NODE_PORT` to use others, and pass them to Conn3x with `-var port=PORT -var node_port=NODE_PORT`. With `CONTAINER_NAME` set, pass it as `-var server_name=NAME` too, since the node reaches the server by it. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes both containers, their network, the CA, the key and the state.
