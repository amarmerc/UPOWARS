# Servidor dedicado de UPOWARS en Docker (Oracle Cloud, Ampere A1 / linux-arm64)

La imagen se construye EN la VM de Oracle: descarga el binario oficial de Godot 4.7.2 para linux arm64 (verificado con SHA-512 contra
`SHA512-SUMS.txt` de la release), importa el proyecto y lo ejecuta desde el codigo con `--headless` (sin GPU, sin audio, sin ventana).
No hacen falta plantillas de exportacion. El juego usa **UDP 7777** (ENet).

```
servidor/
  Dockerfile          multi-stage (descarga+verificacion -> imagen final debian bookworm-slim, usuario sin privilegios, tini, HEALTHCHECK)
  entrypoint.sh       variables de entorno -> argumentos de `-- --servidor`
  healthcheck.sh      sano = el puerto UDP esta abierto (/proc/net/udp)
  docker-compose.yml  puerto UDP, restart unless-stopped, limites 1,5 CPU / 2 GB, segunda instancia comentada
  .env.ejemplo        parametros de partida
  actualizar.sh       git pull + rebuild + restart
  probar_local.ps1    simula el contenedor en Windows (servidor + cliente simulado)
.dockerignore         (raiz) solo entra game/ sin cache, modelos externos, texturas, iconos ni tests
```

## 1. Preparar la VM

Imagen recomendada: Ubuntu 22.04 o 24.04 (aarch64) u Oracle Linux 9 (aarch64), forma `VM.Standard.A1.Flex` (2 OCPU / 12 GB va sobrado).

### Docker en Ubuntu 22.04 / 24.04 (arm64)

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER      # cierra sesion y vuelve a entrar para que surta efecto
docker run --rm hello-world
```

### Docker en Oracle Linux 9 (aarch64)

```bash
sudo dnf install -y dnf-plugins-core git
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER      # cierra sesion y vuelve a entrar
```

(Si el repositorio de RHEL diera problemas en Oracle Linux, `podman` + `podman-compose` tambien sirve, pero esta guia usa Docker.)

## 2. Abrir el puerto UDP 7777 (hay DOS sitios: la nube y la propia VM)

**a) En Oracle Cloud** (consola web): Networking -> Virtual Cloud Networks -> tu VCN -> la Subnet de la VM -> *Security List* (o el NSG de la
VM) -> *Add Ingress Rules*: Source CIDR `0.0.0.0/0`, IP Protocol **UDP**, Destination Port Range `7777` (para varias instancias, `7777-7780`).
Es **UDP**, no TCP. La VM necesita IP publica (mejor reservada, para que no cambie).

**b) En el firewall de la VM**:

- **Ubuntu (imagenes de Oracle)**: traen reglas `iptables` que rechazan todo salvo SSH, aunque `ufw` este inactivo. Inserta la regla ANTES del `REJECT` final:
  ```bash
  sudo iptables -L INPUT -n --line-numbers                 # mira en que numero esta el REJECT (suele ser el 6)
  sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 7777 -j ACCEPT
  sudo apt-get install -y iptables-persistent && sudo netfilter-persistent save    # para que sobreviva al reinicio
  ```
  Si usas `ufw`: `sudo ufw allow 7777/udp` (y que SSH siga permitido: `sudo ufw allow 22/tcp`).
  Docker publica el puerto con sus propias reglas NAT, pero si no conecta, la cadena INPUT de arriba es la primera sospechosa.
- **Oracle Linux 9 (firewalld)**:
  ```bash
  sudo firewall-cmd --permanent --add-port=7777/udp
  sudo firewall-cmd --reload
  ```
  (Docker y firewalld a veces chocan: si tras `--reload` el contenedor deja de publicar, `sudo systemctl restart docker`.)

## 3. Clonar el repositorio (es privado)

Dos opciones, sin guardar secretos en el repo:

- **Deploy key (recomendada)**: en la VM `ssh-keygen -t ed25519 -f ~/.ssh/upowars_deploy -N ""` y copia la clave **publica**
  (`cat ~/.ssh/upowars_deploy.pub`) en GitHub -> repo -> Settings -> Deploy keys -> *Add deploy key* (SIN marcar "Allow write access").
  Luego:
  ```bash
  printf 'Host github-upowars\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/upowars_deploy\n  IdentitiesOnly yes\n' >> ~/.ssh/config
  git clone git@github-upowars:amarmerc/UPOWARS.git ~/UPOWARS
  ```
  (ajusta usuario/nombre del repo si difiere).
- **Token de solo lectura**: GitHub -> Settings -> Developer settings -> Fine-grained tokens, solo ese repo, permiso *Contents: Read-only*.
  `git clone https://github.com/amarmerc/UPOWARS.git` y pega el token cuando pida la contrasena (usuario = tu nombre de GitHub).
  Para no reescribirlo en cada `git pull`: `git config --global credential.helper store` (queda en texto plano en `~/.git-credentials`; con la deploy key no hace falta).

Despues, la rama con el servidor (hoy `red-n1`, o `main` cuando se integre): `cd ~/UPOWARS && git checkout red-n1`.

## 4. Construir y arrancar

```bash
cd ~/UPOWARS/servidor
cp .env.ejemplo .env        # opcional: editar modo, zona, tamano...
docker compose up -d --build
docker compose ps           # STATUS debe pasar a "healthy" en ~1 min
docker compose logs -f --tail 50
```

La primera construccion tarda unos minutos (descarga ~60 MB e importa recursos). En los logs debe verse
`SERVIDOR LISTO udp/7777 max=10 modo=cachimba_wars zona=plaza_america ...`; luego `SERVIDOR peer N conectado`, `partida en marcha`, etc.

Parametros (en `.env` o variables de entorno; sin definir = valor por defecto del servidor):

| Variable | Defecto | Significado |
|---|---|---|
| `PUERTO` | 7777 | puerto UDP |
| `MAX` | 10 | humanos conectados como maximo |
| `MODO` | cachimba_wars | `cachimba_wars`, `pleno` o `libre` |
| `ZONA` | plaza_america | id de zona (ver `game/data/zonas.json`) |
| `TAM` | 5 | jugadores por equipo (humanos + bots) |
| `RONDAS` | 7 | rondas para ganar |
| `DIFICULTAD` | normal | dificultad de los bots |
| `T_COMPRA`, `LAG`, `PERDIDA`, `EXTRA` | (vacio) | solo `docker run` / pruebas (`LAG` en ms, `PERDIDA` en %) |

Cambiar parametros: edita `.env` y `docker compose up -d` (recrea el contenedor). El anfitrion de la sala es el primero que entra: cambia modo/zona/tamano desde el lobby.

Parar: `docker compose down` (envia SIGTERM; el servidor no guarda estado, asi que el cierre es inmediato).

## 5. Conectarse desde el juego

En el lobby: escribe `IP_PUBLICA_DE_LA_VM:7777` en el campo de union y pulsa **Unirse**. Con mas instancias, el puerto de cada una (7778...).
Para saber si llega: mira en los logs de la VM si aparece `SERVIDOR peer ... conectado` al entrar. (`Test-NetConnection` no sirve para UDP.)

## 6. Actualizar

```bash
cd ~/UPOWARS && ./servidor/actualizar.sh      # git pull --ff-only + docker compose up -d --build + limpieza de imagenes viejas
```
Corta las partidas en curso. Cliente y servidor deben ser de la MISMA version (el servidor rechaza versiones distintas).

## 7. Varias instancias

Descomenta `servidor2` en `docker-compose.yml` (otro puerto UDP, p. ej. 7778, y opcionalmente otro modo). Abre ese puerto en Oracle y en el firewall (seccion 2).
Reparte la CPU: la suma de los `cpus` no deberia pasar de ~2 (los 2 OCPU) menos lo que use el sistema.

## 8. Medir CPU / memoria y cuantas partidas caben

```bash
docker stats --no-stream                 # CPU % (100 % = un nucleo) y memoria de cada contenedor
docker stats                             # en vivo mientras se juega
```

Referencia medida en el PC de desarrollo (x86): servidor con 2 humanos simulados + 8 bots ~ **12 % de un nucleo y ~350 MB** (README principal, seccion Red).
Un nucleo Ampere A1 es varias veces mas lento por hilo: cuenta ~40-60 % de un nucleo por partida de 10 participantes (ESTIMACION SIN MEDIR en ARM; mide
con `docker stats` mientras juegan clientes reales). Orden de magnitud: con 2 OCPU caben **2-3 partidas simultaneas** (instancias), y la RAM (12 GB) no es el limite
(~0,4-0,6 GB por instancia). El ancho de banda es ~4-6 KB/s por jugador en cada sentido (~100 kbit/s por partida de 10), irrelevante.
Si `docker stats` muestra la instancia pegada al limite de `cpus`, el servidor ira con retraso (fisica a 60 Hz): sube el limite o baja `TAM`.

## 9. Probar sin Docker (en un PC con Windows)

```powershell
powershell -File servidor\probar_local.ps1                  # mismos argumentos que el contenedor; arranca un cliente simulado y comprueba que entra
powershell -File servidor\probar_local.ps1 -ConBash         # ejecuta servidor/entrypoint.sh de verdad (necesita Git Bash)
```

## 10. Alternativa (no por defecto): exportar un .pck

En lugar de ejecutar el codigo, se puede exportar `game/` con las plantillas de exportacion de Godot 4.7.2 (preset Linux ARM64, "Export PCK/ZIP") y
meter en la imagen solo el binario + el `.pck` (`godot --headless --main-pack juego.pck -- --servidor ...`). Arranca algo mas rapido, pero exige instalar las
plantillas en el PC y regenerar el .pck en cada cambio. Con el enfoque actual basta `git pull` + `docker compose up -d --build`.

## Notas de seguridad y operacion

- El contenedor corre como usuario `upowars` (uid 10001), sin privilegios; solo publica el puerto UDP.
- El servidor no autentica jugadores: quien conozca IP:puerto puede unirse (hasta `MAX`). Para limitarlo, restringe el CIDR de origen en la Security List.
- Los logs rotan (3 x 10 MB).
