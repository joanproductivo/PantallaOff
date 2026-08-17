/* PantallaOff — web. JavaScript de vainilla, sin dependencias.
   Todo lo de aquí es mejora progresiva: sin JS la página se lee entera. */

(function () {
  'use strict';

  var html = document.documentElement;
  html.classList.add('js');

  var t = {
    copy:    html.dataset.copy || 'Copy',
    copied:  html.dataset.copied || 'Copied',
    menuOff: html.dataset.menuOff || 'Turn off MacBook display',
    menuOn:  html.dataset.menuOn || 'Turn on MacBook display'
  };

  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------- Barra de navegación: sombra al desplazarse ---------- */
  var nav = document.getElementById('nav');
  if (nav) {
    var onScroll = function () { nav.classList.toggle('is-stuck', window.scrollY > 12); };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  /* ---------- Réplica del menú ----------
     Reproduce el comportamiento real: los interruptores se aplican en el sitio
     y el ítem de apagar se re-etiqueta. */
  var stage = document.getElementById('stage');
  var toggle = document.getElementById('menu-toggle');

  if (toggle && stage) {
    toggle.addEventListener('click', function () {
      var off = toggle.getAttribute('aria-pressed') === 'true';
      toggle.setAttribute('aria-pressed', off ? 'false' : 'true');
      stage.classList.toggle('is-off', !off);
      toggle.querySelector('.menu-label').textContent = off ? t.menuOff : t.menuOn;
    });
  }

  document.querySelectorAll('.menu-item[data-toggle]').forEach(function (item) {
    item.addEventListener('click', function () {
      var on = item.getAttribute('aria-pressed') === 'true';
      item.setAttribute('aria-pressed', on ? 'false' : 'true');
      if (item.hasAttribute('data-kb') && stage) stage.classList.toggle('kb-off', !on);
    });
  });

  /* ---------- Copiar los comandos ---------- */
  document.querySelectorAll('[data-copy-target]').forEach(function (box) {
    var button = box.querySelector('.copy');
    var code = box.querySelector('code');
    if (!button || !code || !navigator.clipboard) { if (button) button.remove(); return; }

    button.textContent = t.copy;
    button.addEventListener('click', function () {
      navigator.clipboard.writeText(code.textContent.trim()).then(function () {
        button.textContent = t.copied;
        button.classList.add('is-done');
        setTimeout(function () {
          button.textContent = t.copy;
          button.classList.remove('is-done');
        }, 1800);
      }).catch(function () { /* sin portapapeles: el usuario puede seleccionar el texto */ });
    });
  });

  /* ---------- Aparición al entrar en pantalla ---------- */
  var revealables = document.querySelectorAll('.reveal');
  if (reduced || !('IntersectionObserver' in window)) {
    revealables.forEach(function (el) { el.classList.add('is-in'); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-in');
        io.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.06 });
    revealables.forEach(function (el) { io.observe(el); });
  }

  /* ---------- Sugerencia de idioma ----------
     Nunca redirige: sólo ofrece la otra versión si el navegador la prefiere. */
  var nudge = document.getElementById('lang-nudge');
  if (nudge) {
    var pageLang = html.dataset.lang;
    var other = pageLang === 'es' ? 'en' : 'es';
    var prefersOther = (navigator.languages || [navigator.language || ''])
      .some(function (l) { return String(l).toLowerCase().indexOf(other) === 0; });
    var dismissed = false;
    try { dismissed = localStorage.getItem('po-lang-nudge') === '1'; } catch (e) {}

    if (prefersOther && !dismissed) {
      setTimeout(function () { nudge.hidden = false; }, 1200);
      nudge.querySelector('.nudge-close').addEventListener('click', function () {
        nudge.hidden = true;
        try { localStorage.setItem('po-lang-nudge', '1'); } catch (e) {}
      });
    }
  }

  /* ---------- Versión publicada ----------
     Si GitHub responde, la insignia muestra la última release sin tener que
     tocar el HTML. Si no responde, se queda la versión escrita a mano. */
  var badge = document.getElementById('version-badge');
  if (badge && window.fetch) {
    fetch('https://api.github.com/repos/joanproductivo/PantallaOff/releases/latest',
          { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data || !data.tag_name) return;
        var tag = String(data.tag_name);
        badge.textContent = tag.charAt(0) === 'v' ? tag : 'v' + tag;
      })
      .catch(function () { /* sin red o con el límite de la API agotado: da igual */ });
  }
})();
