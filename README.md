# Dory Port Forwarder (Dory PF) ⚡

<p align="center">
  <img src="icon.png" width="128" height="128" alt="Dory PF Icon" />
</p>

**Dory Port Forwarder (Dory PF)** es una aplicación nativa para macOS (Menu Bar App) desarrollada en Swift y SwiftUI. Su función es facilitar la redirección y el reenvío de puertos locales en entornos macOS (especialmente útil para desarrollo local con **Dory**, Docker o OrbStack), todo de forma ligera, segura y con **0% de consumo de CPU** cuando está inactiva.

Usa el motor de filtrado de paquetes nativo de macOS (**PF - Packet Filter**) a través de una única regla segura de redirección en bucle local (`rdr pass`), evitando configuraciones complejas que alteren la seguridad global de tu sistema.

---

## ✨ Características

*   **⚡ Rendimiento Óptimo (Híbrido):** La aplicación solo realiza chequeos y consume recursos cuando la ventana de la barra de menú está abierta. Al cerrarse, se detiene por completo (0% uso de CPU).
*   **🐳 Integración Automática con Docker (Dory):** Detecta en tiempo real qué contenedores están corriendo a través de una conexión directa de bajo nivel con el socket `/Users/USER/.dory/dory.sock` y te sugiere las redirecciones apropiadas en 1 clic.
*   **⚠️ Detección Inteligente de Conflictos:** Te alerta al instante si el puerto de entrada local ya está ocupado por otra aplicación y te muestra qué proceso (ej: `httpd`, `Ollama`, `Dory`, etc.) lo está bloqueando en un tooltip detallado.
*   **🟢 Estatus de Destino en Vivo:** Te indica en tiempo real mediante indicadores visuales si el puerto de destino (ej: tu contenedor Docker) está activo y escuchando conexiones.
*   **📁 Gestión de Perfiles:** Crea, selecciona y organiza tus conjuntos de reglas en diferentes perfiles (ej. Desarrollo, Producción, Test).
*   **🔒 Instalación Segura y Automatizada:** En el primer arranque, la aplicación te guiará para instalar el daemon persistente de macOS (`launchd`) mediante una única solicitud segura con privilegios de administrador.
*   **📦 100% Nativo y sin Dependencias:** Pesa menos de 1 MB, no requiere Node.js, Electron ni librerías de terceros.

---

## 🛠️ Arquitectura de Funcionamiento

Dory PF utiliza un enfoque desacoplado y seguro:
1.  **La Interfaz Gráfica (Swift/SwiftUI):** Lee y escribe las reglas de desvío de puertos en un archivo de texto plano ubicado en tu directorio de usuario: `~/.dory/port-forwards.conf`.
2.  **El Daemon de macOS (`launchd`):** Un script minimalista (`dory-pf.sh`) instalado en `/usr/local/libexec/` que es administrado por un LaunchDaemon (`local.dory-pf.plist`). Este daemon vigila el archivo de configuración y se activa instantáneamente solo cuando realizas un cambio, aplicando las reglas en el ancla nativa `/etc/pf.conf` sin bloquear tu cortafuegos.

---

## 📥 Instalación

### Requisitos
*   macOS 13.0 (Ventura) o superior.
*   Dory, Docker Desktop u OrbStack instalado y ejecutándose.

### Compilar y Empaquetar
Para generar tu aplicación nativa empaquetada con su icono de forma automática, simplemente clona el repositorio y ejecuta el script de construcción:

```bash
chmod +x build.sh
./build.sh
```

Esto generará el paquete **`DoryPortForwarder.app`** en el directorio raíz. Puedes arrastrar este archivo a tu carpeta de `/Applications` (Aplicaciones) en macOS y añadirlo a tus ítems de inicio si lo deseas.

---

## 🚀 Uso de la Aplicación

1.  **Arranque Inicial (Onboarding):** Al abrir la app por primera vez, detectará que el servicio no está instalado y te mostrará un botón de **Instalar**. Al pulsarlo, macOS te pedirá privilegios para configurar el script de firewall seguro.
2.  **Añadir Reglas:**
    *   **Manual:** Introduce el puerto origen (ej: `80`) y el puerto destino (ej: `8081`) y pulsa **Add**.
    *   **Docker (1 clic):** Si tienes contenedores Docker corriendo con puertos mapeados, aparecerán en la sección **Suggested Forwards (Docker)**. Pulsa el botón `[+]` y se agregará inmediatamente.
3.  **Comprobación de Conflictos:** Si ves un triángulo rojo `⚠️`, pasa el ratón por encima para ver qué proceso local está ocupando el puerto de entrada.
4.  **Perfiles:** Utiliza el menú desplegable superior para cambiar entre perfiles de redirección en segundos.

---

## 📄 Licencia

Este proyecto está bajo la Licencia MIT - lee el archivo [LICENSE](LICENSE) para más detalles.

---

## 🤝 Contribuciones

Las sugerencias, pull requests y reportes de issues son bienvenidos. Si quieres mejorar el soporte para otros sockets o agregar integraciones, no dudes en abrir una propuesta.
