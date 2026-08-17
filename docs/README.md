# Web de PantallaOff

Sitio estático bilingüe (inglés en `/`, español en `/es/`) publicado en
**<https://pantallaoff.joanproductivo.com>**. HTML, CSS y JavaScript de vainilla, sin
dependencias, sin compilación y sin nada que instalar: son ficheros que se sirven tal cual.

```
docs/
  index.html          inglés  (hreflang x-default)
  es/index.html       español
  assets/styles.css   hoja de estilos única
  assets/app.js       mejora progresiva (menú interactivo, copiar, revelado)
  assets/icon.svg     el icono de la app, redibujado como SVG (favicon y logo)
  assets/og.jpg       tarjeta Open Graph en inglés   ← generada por tools/make-og.swift
  assets/og.es.jpg    tarjeta Open Graph en español  ← ídem
  robots.txt · sitemap.xml · .nojekyll
```

## Cómo se publica

Está en Dokploy, en la aplicación `PantallaOff` del proyecto `wordpress`
(`wordpress-pantallaoff-hhlnhm`). La configuración que hace que se publique **sólo esta
carpeta** y no el resto del repositorio:

| Ajuste | Valor | Por qué |
|---|---|---|
| Source | GitHub · `joanproductivo/PantallaOff` · rama `main` | |
| Build path | `/` | la raíz del repositorio es el contexto de compilación |
| Build type | **Static** | nginx sirviendo ficheros, sin runtime ni build step |
| **Publish directory** | **`docs`** | **la clave: sólo se sirve esta carpeta** |
| SPA mode | desactivado | `/es/` es un directorio real, y un 404 debe ser un 404 |
| Dominio | `pantallaoff.joanproductivo.com` · puerto 80 · HTTPS con Let's Encrypt | |

Dokploy clona el repositorio entero (no hay forma de clonar media rama), pero la imagen que
acaba corriendo sólo contiene `docs/`. El código de la app, el `Makefile` y las herramientas
no se publican en ningún momento.

**El despliegue es automático**: `autoDeploy` está activado, así que cada `git push` a `main`
reconstruye y republica el sitio. No hace falta tocar Dokploy para actualizar la web.

Ojo con eso: un push que sólo toque el código de la app también dispara un redespliegue de la
web. Es inofensivo — el resultado es idéntico — pero explica por qué aparecen despliegues que
no tienen nada que ver con `docs/`.

## Si algún día cambia el dominio

Las URLs absolutas (canonical, hreflang, Open Graph, JSON-LD, sitemap y robots) apuntan a
`https://pantallaoff.joanproductivo.com/`. **Hay que sustituirlas si el dominio cambia**, o
Google indexará el dominio equivocado:

```bash
grep -rl 'pantallaoff.joanproductivo.com' docs \
  | xargs sed -i '' 's|https://pantallaoff.joanproductivo.com/|https://TU-DOMINIO.com/|g'
```

Y en Dokploy, cambiar el `host` del dominio de la aplicación. Las rutas de los recursos son
relativas a propósito, así que el sitio funciona igual en la raíz de un dominio, en un
subdirectorio o abriendo los ficheros en local: lo único absoluto es lo que los buscadores
exigen absoluto.

## Verla en local

```bash
python3 -m http.server 4173 --directory docs
```

Y abre <http://localhost:4173>. Ábrela por HTTP, no con doble clic: con `file://` el navegador
bloquea parte del JavaScript y las rutas relativas no se resuelven igual.

## Regenerar las tarjetas Open Graph

Se dibujan por código, como el icono de la app, para que no haya binarios opacos en el repo:

```bash
swift tools/make-og.swift en docs/assets/og.jpg
swift tools/make-og.swift es docs/assets/og.es.jpg
```

## Al sacar una versión nueva

La insignia de versión del hero se actualiza sola: `app.js` pregunta a la API de GitHub por la
última release y, si responde, reescribe la etiqueta. El `v1.2.1` del HTML es sólo el respaldo
para cuando no hay red. Conviene refrescarlo de vez en cuando en los dos idiomas, junto al
`softwareVersion` del JSON-LD.

## Mantener las dos versiones a la vez

El inglés y el español son ficheros hermanos con la misma estructura, sección por sección: si
tocas uno, toca el otro. Las cadenas que necesita el JavaScript viajan en atributos `data-` del
`<html>` (`data-copy`, `data-copied`, `data-menu-off`, `data-menu-on`), así que `app.js` no
tiene ni una palabra traducible dentro.
