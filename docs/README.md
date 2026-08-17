# Web de PantallaOff

Sitio estático bilingüe (inglés en `/`, español en `/es/`). HTML, CSS y JavaScript de vainilla,
sin dependencias, sin compilación y sin nada que instalar: son ficheros que se suben tal cual.

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

## AL PUBLICAR EN UN DOMINIO PROPIO: cambia la URL base

Las URLs absolutas (canonical, hreflang, Open Graph, JSON-LD, sitemap y robots) apuntan hoy a
`https://joanproductivo.github.io/PantallaOff/`, que es donde funcionan sin tocar nada. **Si
publicas en otro dominio hay que sustituirla**, o Google indexará el dominio equivocado:

```bash
grep -rl 'joanproductivo.github.io/PantallaOff' docs \
  | xargs sed -i '' 's|https://joanproductivo.github.io/PantallaOff/|https://TU-DOMINIO.com/|g'
```

Las rutas de los recursos son relativas a propósito, así que el sitio funciona igual en la raíz
de un dominio, en un subdirectorio o abriendo los ficheros en local. Lo único absoluto es lo
que los buscadores exigen absoluto.

Si sirves desde un dominio propio con GitHub Pages, añade también un fichero `CNAME` en esta
carpeta con el dominio dentro (una línea, sin `https://`).

## Publicar en GitHub Pages

Ajustes del repositorio → Pages → Source: *Deploy from a branch* → rama `main`, carpeta
`/docs`. El `.nojekyll` está para que Pages sirva la carpeta tal cual, sin pasarla por Jekyll.

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
