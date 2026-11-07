"""JavaScript injected into the rendered page, and the split of its result.

The extractors run inside the page and return plain JSON. Everything they
return is untrusted page data; the Python side only reshapes it.
"""

from typing import Any

# Reads every navigation landmark as a tree of {label, url, children}. Run
# repeatedly while menus are revealed; the results are merged in
# analysis.navigation.
NAVIGATION_EXTRACTOR_JS = r"""
() => {
  function textOf(el) {
    return (el?.innerText || el?.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  }
  function labelOf(el) {
    return textOf(el) || el?.getAttribute?.('aria-label') || '';
  }
  function absoluteUrl(value) {
    try { return value ? new URL(value, location.href).href : ''; } catch (_) { return value || ''; }
  }
  function directContainer(anchor, root) {
    let current = anchor;
    while (current.parentElement && current.parentElement !== root) current = current.parentElement;
    return current;
  }
  function itemFromContainer(container) {
    const control = container.matches?.('a[href]')
      ? container
      : container.querySelector(':scope > a[href], :scope > * > a[href]');
    if (!control) return null;
    const descendants = Array.from(container.querySelectorAll('a[href]'))
      .filter((anchor) => anchor !== control);
    const seen = new Set();
    const children = descendants.map((anchor) => {
      const url = absoluteUrl(anchor.getAttribute('href') || '');
      const label = labelOf(anchor) || url;
      const key = `${url}|${label}`;
      if (!label || seen.has(key)) return null;
      seen.add(key);
      return {label, url, children: []};
    }).filter(Boolean).slice(0, 160);
    const url = absoluteUrl(control.getAttribute('href') || '');
    return {label: labelOf(control) || url, url, children};
  }
  function itemFromListItem(item, depth = 0) {
    if (depth > 7) return null;
    const control = item.querySelector(':scope > a[href], :scope > * > a[href]');
    if (!control) return null;
    const childList = item.querySelector(':scope > ul, :scope > ol, :scope > * > ul, :scope > * > ol');
    const children = childList
      ? Array.from(childList.children)
          .filter((child) => child.matches('li'))
          .map((child) => itemFromListItem(child, depth + 1))
          .filter(Boolean)
      : [];
    const url = absoluteUrl(control.getAttribute('href') || '');
    return {label: labelOf(control) || url, url, children};
  }
  function itemsFromContainer(container) {
    const anchors = Array.from(container.querySelectorAll?.('a[href]') || []);
    const list = container.matches?.('ul, ol')
      ? container
      : container.querySelector?.(':scope > ul, :scope > ol');
    if (list) {
      return Array.from(list.children)
        .filter((child) => child.matches('li'))
        .map((child) => itemFromListItem(child))
        .filter(Boolean);
    }
    const ownsSubmenu = Array.from(container.querySelectorAll?.('button[aria-expanded]') || [])
      .some((button) => button.hasAttribute('aria-haspopup') || /menu|menü/i.test(button.getAttribute('aria-label') || ''));
    if (!ownsSubmenu && anchors.length > 1) {
      return anchors.map((anchor) => ({
        label: labelOf(anchor) || absoluteUrl(anchor.getAttribute('href') || ''),
        url: absoluteUrl(anchor.getAttribute('href') || ''),
        children: [],
      }));
    }
    const item = itemFromContainer(container);
    return item ? [item] : [];
  }

  return Array.from(document.querySelectorAll('nav, [role="navigation"]')).map((root, index) => {
    const containers = [];
    const seen = new Set();
    for (const anchor of root.querySelectorAll('a[href]')) {
      const container = directContainer(anchor, root);
      if (!seen.has(container)) {
        seen.add(container);
        containers.push(container);
      }
    }
    return {
      label: root.getAttribute('aria-label') || root.getAttribute('title') || `Navigation ${index + 1}`,
      items: containers.flatMap(itemsFromContainer).filter(Boolean).slice(0, 80),
    };
  }).filter((group) => group.items.length > 0).slice(0, 12);
}
"""


# Reads computed styles, assets, SEO, accessibility findings, responsive
# issues and technology signals for one viewport. Its top-level keys become
# the viewport document (see document.assemble_viewport), except the private
# "_technology_signals" and the legacy "navigation" key, which split_extraction
# removes.
VISUAL_EXTRACTOR_JS = r"""
(inspection) => {
  const selectors = [
    'body', 'header', 'nav', 'main', 'section', 'article',
    'h1', 'h2', 'h3', 'p', 'a', 'button',
    '[class*="hero" i]', '[class*="card" i]', '[class*="btn" i]',
    '[class*="cta" i]', '[role="button"]'
  ];
  const seen = new Set();
  const samples = [];

  function textOf(el) {
    if (!el) return '';
    return (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  }

  function attr(el, name) {
    if (!el) return '';
    return el.getAttribute(name) || '';
  }

  function absoluteUrl(value) {
    try { return value ? new URL(value, location.href).href : ''; } catch (_) { return value || ''; }
  }

  function metaBy(selector) {
    return document.querySelector(selector)?.content || '';
  }

  function allMeta(prefix) {
    return Array.from(document.querySelectorAll(`meta[${prefix}]`)).map((el) => ({
      name: attr(el, prefix),
      content: attr(el, 'content')
    })).filter((item) => item.name || item.content).slice(0, 80);
  }

  function selectorHint(el) {
    if (el.id) return `#${el.id}`;
    if (el.className && typeof el.className === 'string') {
      return '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.');
    }
    return el.tagName.toLowerCase();
  }

  function styleOf(el) {
    const s = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      selector_hint: selectorHint(el),
      text: textOf(el),
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
      display: s.display,
      position: s.position,
      font_family: s.fontFamily,
      font_size: s.fontSize,
      font_weight: s.fontWeight,
      line_height: s.lineHeight,
      color: s.color,
      background_color: s.backgroundColor,
      border_radius: s.borderRadius,
      box_shadow: s.boxShadow,
      letter_spacing: s.letterSpacing,
      text_transform: s.textTransform,
      margin: `${s.marginTop} ${s.marginRight} ${s.marginBottom} ${s.marginLeft}`,
      padding: `${s.paddingTop} ${s.paddingRight} ${s.paddingBottom} ${s.paddingLeft}`,
    };
  }

  for (const selector of selectors) {
    for (const el of Array.from(document.querySelectorAll(selector)).slice(0, 24)) {
      if (seen.has(el) || samples.length >= 90) continue;
      const rect = el.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8) continue;
      seen.add(el);
      samples.push(styleOf(el));
    }
  }

  const colorSet = new Set();
  const fontSet = new Set();
  for (const item of samples) {
    if (item.color && item.color !== 'rgba(0, 0, 0, 0)') colorSet.add(item.color);
    if (item.background_color && item.background_color !== 'rgba(0, 0, 0, 0)') colorSet.add(item.background_color);
    if (item.font_family) fontSet.add(item.font_family);
  }

  // Custom properties, ordered so that the ones carrying a design decision
  // survive the cap applied further down.
  //
  // This used to ship the raw iteration order and slice it. Utility frameworks
  // register a large number of bookkeeping properties on :root (Tailwind alone
  // emits dozens of --tw-* placeholders holding "0 0 #0000" or an empty string),
  // and on such a site those could consume the entire budget, so the tokens the
  // page actually defines never left the browser at all. No amount of filtering
  // in the app can recover a value that was never sent.
  const rootStyles = window.getComputedStyle(document.documentElement);
  const meaningfulVariables = [];
  const placeholderVariables = [];
  // Values a framework parks on :root purely so a later rule can override them.
  const placeholderValues = new Set([
    '', '0', '0s', '0px', 'none', 'solid', 'initial', 'auto',
    // Lowercase throughout: matched against value.toLowerCase() below.
    '0 0 #0000', 'border-box', 'content-box', 'translatex(0)', 'translate(0)',
    'normal', '1', '100%',
  ]);
  for (const name of rootStyles) {
    if (!name.startsWith('--')) continue;
    const value = rootStyles.getPropertyValue(name).trim();
    const entry = {name, value};
    if (placeholderValues.has(value.toLowerCase())) {
      placeholderVariables.push(entry);
    } else {
      meaningfulVariables.push(entry);
    }
  }
  // Placeholders are kept rather than dropped: a site may legitimately define a
  // token whose value happens to look like one, and the app shows them in a
  // collapsed group. They just no longer crowd out the real tokens.
  const cssVariables = meaningfulVariables.concat(placeholderVariables);

  const imgAssets = Array.from(document.images).map((img) => ({
    kind: 'image',
    url: img.currentSrc || img.src || '',
    alt: attr(img, 'alt'),
    width: img.naturalWidth || img.width || 0,
    height: img.naturalHeight || img.height || 0,
    loading: attr(img, 'loading'),
    selector_hint: selectorHint(img),
  })).filter((item) => item.url).slice(0, 120);

  const iconAssets = Array.from(document.querySelectorAll('link[rel*="icon" i], link[rel*="apple-touch-icon" i]')).map((el) => ({
    kind: 'icon',
    url: absoluteUrl(attr(el, 'href')),
    rel: attr(el, 'rel'),
    sizes: attr(el, 'sizes'),
    type: attr(el, 'type')
  })).filter((item) => item.url).slice(0, 40);

  const styleAssets = Array.from(document.querySelectorAll('link[rel="stylesheet"]')).map((el) => ({
    kind: 'stylesheet',
    url: absoluteUrl(attr(el, 'href')),
    media: attr(el, 'media')
  })).filter((item) => item.url).slice(0, 80);

  const scriptAssets = Array.from(document.scripts).map((el) => ({
    kind: 'script',
    url: absoluteUrl(attr(el, 'src')),
    async: el.async,
    defer: el.defer,
    type: attr(el, 'type')
  })).filter((item) => item.url).slice(0, 80);

  const sameOrigin = (url) => {
    try { return new URL(url, location.href).origin === location.origin; } catch (_) { return false; }
  };
  const sameOriginStylesheets = styleAssets.filter((item) => sameOrigin(item.url));
  const sameOriginScripts = scriptAssets.filter((item) => sameOrigin(item.url));
  const moduleScripts = scriptAssets.filter((item) => item.type === 'module');
  const resourceUrls = performance.getEntriesByType('resource')
    .map((entry) => entry.name || '')
    .filter(Boolean);
  const selfHostedFontUrls = resourceUrls.filter((url) =>
    sameOrigin(url) && /\.(?:woff2?|ttf|otf)(?:\?|$)/i.test(url)
  );

  const links = Array.from(document.querySelectorAll('a[href]')).map((a) => {
    const href = absoluteUrl(attr(a, 'href'));
    let isExternal = false;
    try { isExternal = new URL(href).origin !== location.origin; } catch (_) {}
    return {url: href, text: textOf(a), external: isExternal};
  }).filter((item) => item.url);

  const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).map((heading) => ({
    level: Number(heading.tagName.slice(1)),
    text: textOf(heading),
  })).filter((item) => item.text).slice(0, 120);

  const missingAltImages = imgAssets.filter((img) => !img.alt).slice(0, 80);
  const emptyButtons = Array.from(document.querySelectorAll('button, [role="button"]')).map((button) => ({
    selector_hint: selectorHint(button),
    text: textOf(button),
    aria_label: attr(button, 'aria-label')
  })).filter((button) => !button.text && !button.aria_label).slice(0, 80);

  const unlabeledInputs = Array.from(document.querySelectorAll('input, textarea, select')).map((input) => {
    const id = attr(input, 'id');
    const label = id ? document.querySelector(`label[for="${CSS.escape(id)}"]`) : null;
    const wrappedLabel = input.closest('label');
    return {
      selector_hint: selectorHint(input),
      type: attr(input, 'type') || input.tagName.toLowerCase(),
      name: attr(input, 'name'),
      placeholder: attr(input, 'placeholder'),
      label: textOf(label || wrappedLabel),
      aria_label: attr(input, 'aria-label'),
    };
  }).filter((input) => !input.label && !input.aria_label).slice(0, 80);

  const headingSkips = [];
  for (let i = 1; i < headings.length; i += 1) {
    if (headings[i].level - headings[i - 1].level > 1) {
      headingSkips.push({from: headings[i - 1], to: headings[i]});
    }
  }

  const responsiveIssues = [];
  const issueKeys = new Set();
  const severityOrder = {high: 0, medium: 1, low: 2};

  function addIssue(kind, severity, title, detail, el, metric = '') {
    const rect = el?.getBoundingClientRect?.() || {left: 0, top: 0, width: innerWidth, height: 1};
    const selector = el ? selectorHint(el) : 'html';
    const key = `${kind}:${selector}:${Math.round(rect.left)}:${Math.round(rect.top)}`;
    if (issueKeys.has(key) || responsiveIssues.length >= 60) return;
    issueKeys.add(key);
    responsiveIssues.push({
      id: key,
      kind,
      severity,
      title,
      detail,
      selector_hint: selector,
      text: el ? textOf(el) : '',
      x: Math.max(0, Math.round(rect.left + scrollX)),
      y: Math.max(0, Math.round(rect.top + scrollY)),
      width: Math.max(1, Math.round(rect.width)),
      height: Math.max(1, Math.round(rect.height)),
      metric,
    });
  }

  const documentWidth = Math.max(
    document.documentElement.scrollWidth,
    document.body?.scrollWidth || 0
  );
  const viewportMeta = document.querySelector('meta[name="viewport"]');
  if (inspection?.is_touch && !viewportMeta) {
    addIssue(
      'missing_viewport_meta',
      'high',
      'Mobile viewport configuration is missing',
      'Without a viewport meta tag, mobile browsers may render the page at a desktop-like width.',
      document.documentElement,
      'meta[name="viewport"] not found'
    );
  }
  if (documentWidth > innerWidth + 2) {
    addIssue(
      'horizontal_overflow',
      'high',
      'Page overflows horizontally',
      `The rendered page is ${documentWidth - innerWidth}px wider than this viewport.`,
      document.documentElement,
      `${documentWidth}px document / ${innerWidth}px viewport`
    );
  }

  function clippedByAncestor(el) {
    if (getComputedStyle(el).position === 'fixed') return false;
    for (let node = el.parentElement; node && node !== document.documentElement; node = node.parentElement) {
      if (['hidden', 'clip', 'auto', 'scroll'].includes(getComputedStyle(node).overflowX)) return true;
    }
    return false;
  }

  const visibleElements = Array.from(document.body?.querySelectorAll('*') || [])
    .slice(0, 2500)
    .filter((el) => {
      const rect = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      return rect.width > 1 && rect.height > 1 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity || 1) > 0;
    });

  for (const el of visibleElements) {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    const text = textOf(el);

    // Only a partly visible element is cut off for the reader. One entirely
    // outside the viewport is a parked slide or a closed off-canvas menu,
    // and one an ancestor clips (sliders, logo strips) never reaches the
    // edge; a page that really scrolls sideways is reported as
    // horizontal_overflow above.
    const partlyVisible = rect.right > 0 && rect.left < innerWidth;
    if (partlyVisible && (rect.right > innerWidth + 3 || rect.left < -3) && !clippedByAncestor(el)) {
      const outside = Math.max(rect.right - innerWidth, -rect.left);
      if (outside >= 4 && rect.width < documentWidth * 0.98) {
        addIssue(
          'offscreen_element',
          outside > 40 ? 'high' : 'medium',
          'Element extends beyond the viewport',
          `This element is approximately ${Math.round(outside)}px outside the visible width.`,
          el,
          `${Math.round(rect.width)}x${Math.round(rect.height)}px`
        );
      }
    }

    const clipsX = el.scrollWidth > el.clientWidth + 3 && ['hidden', 'clip'].includes(style.overflowX);
    const clipsY = el.scrollHeight > el.clientHeight + 3 && ['hidden', 'clip'].includes(style.overflowY);
    if (text && (clipsX || clipsY)) {
      addIssue(
        'clipped_content',
        'medium',
        'Content may be clipped',
        'The content is larger than its box while overflow is hidden.',
        el,
        `${el.scrollWidth}x${el.scrollHeight}px content / ${el.clientWidth}x${el.clientHeight}px box`
      );
    }

    const fontSize = parseFloat(style.fontSize || '0');
    if (text && fontSize > 0 && fontSize < 12 && rect.width >= 12 && rect.height >= 6) {
      addIssue(
        'small_text',
        fontSize < 10 ? 'medium' : 'low',
        'Very small text',
        'This text may be difficult to read at the selected viewport.',
        el,
        `${fontSize}px`
      );
    }

    const isInteractive = el.matches('a[href],button,input,select,textarea,[role="button"],[tabindex]:not([tabindex="-1"])');
    if (innerWidth <= 900 && isInteractive && (rect.width < 44 || rect.height < 44)) {
      addIssue(
        'small_touch_target',
        rect.width < 28 || rect.height < 28 ? 'medium' : 'low',
        'Small touch target',
        'This control is smaller than the recommended 44x44px touch area.',
        el,
        `${Math.round(rect.width)}x${Math.round(rect.height)}px`
      );
    }

    if (['fixed', 'sticky'].includes(style.position) && rect.height > innerHeight * 0.3) {
      addIssue(
        'large_sticky_element',
        'medium',
        'Sticky element covers much of the viewport',
        'This fixed or sticky element occupies more than 30% of the viewport height.',
        el,
        `${Math.round((rect.height / innerHeight) * 100)}% of viewport height`
      );
    }
  }

  const interactiveElements = visibleElements
    .filter((el) => el.matches('a[href],button,input,select,textarea,[role="button"]'))
    .slice(0, 160);
  for (let i = 0; i < interactiveElements.length; i += 1) {
    const first = interactiveElements[i];
    const a = first.getBoundingClientRect();
    for (let j = i + 1; j < interactiveElements.length; j += 1) {
      const second = interactiveElements[j];
      if (first.contains(second) || second.contains(first)) continue;
      const b = second.getBoundingClientRect();
      const overlapWidth = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
      const overlapHeight = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
      const overlapArea = overlapWidth * overlapHeight;
      const smallerArea = Math.max(1, Math.min(a.width * a.height, b.width * b.height));
      if (overlapArea / smallerArea >= 0.2) {
        addIssue(
          'overlapping_controls',
          'high',
          'Interactive controls overlap',
          `This control overlaps another interactive element (${selectorHint(second)}).`,
          first,
          `${Math.round((overlapArea / smallerArea) * 100)}% overlap`
        );
      }
    }
  }

  responsiveIssues.sort((a, b) =>
    (severityOrder[a.severity] ?? 9) - (severityOrder[b.severity] ?? 9)
  );

  const runtimeProbe = Array.from(document.querySelectorAll('*')).slice(0, 500);
  const runtimeMarkers = [];
  const mark = (name, condition) => { if (condition) runtimeMarkers.push(name); };
  mark('WordPress', Boolean(
    document.querySelector('link[rel="https://api.w.org/"], link[href*="wp-json"], [class*="wp-block-"]')
  ));
  mark('Shopify', Boolean(window.Shopify || document.querySelector('[data-shopify]')));
  mark('Webflow', Boolean(
    window.Webflow || document.documentElement.hasAttribute('data-wf-page') ||
    document.documentElement.hasAttribute('data-wf-site')
  ));
  mark('Framer', Boolean(document.querySelector('[data-framer-name], [data-framer-component-type]')));
  mark('Drupal', Boolean(window.drupalSettings || document.querySelector('[data-drupal-selector]')));
  mark('Next.js', Boolean(document.querySelector('#__next, script#__NEXT_DATA__')));
  mark('Nuxt', Boolean(document.querySelector('#__nuxt') || window.__NUXT__));
  mark('Astro', Boolean(document.querySelector('astro-island, astro-slot')));
  mark('Gatsby', Boolean(document.querySelector('#___gatsby') || window.___gatsby));
  mark('SvelteKit', Boolean(document.querySelector('[data-sveltekit-preload-data], [data-sveltekit-preload-code]')));
  mark('Angular', Boolean(document.querySelector('[ng-version], app-root')));
  mark('Vue', Boolean(
    window.__VUE__ || document.querySelector('[data-v-app]') ||
    runtimeProbe.some((el) => Boolean(el.__vue_app__))
  ));
  mark('React', runtimeProbe.some((el) =>
    Object.keys(el).some((key) => key.startsWith('__reactFiber$') || key.startsWith('__reactContainer$'))
  ));
  mark('Tailwind CSS', cssVariables.some((item) => item.name.startsWith('--tw-')));
  const hasTanStackRouter = Boolean(document.querySelector('[data-route-announcer]'));
  mark('TanStack Router', hasTanStackRouter);
  mark('TanStack Start', hasTanStackRouter && Boolean(window.$R));
  mark('SSR + Hydration', hasTanStackRouter && Boolean(window.$R));
  mark('Radix UI', Boolean(document.querySelector('[data-radix-collection-item], [id^="radix-"]')));
  mark('Lucide', Boolean(document.querySelector('svg.lucide, [class*="lucide-"]')));
  mark('Plausible', scriptAssets.some((item) => /plausible(?:\.min)?\.js|plausible\.io/i.test(item.url)));
  mark('Google Analytics 4', Boolean(
    document.querySelector('meta[name="ga4-measurement-id"]') ||
    scriptAssets.some((item) => /googletagmanager\.com\/gtag\/js/i.test(item.url))
  ));
  mark('Custom CSS', sameOriginStylesheets.length > 0);
  mark('CSS Design Tokens', meaningfulVariables.length >= 4);
  mark('Self-hosted Fonts', selfHostedFontUrls.length > 0);
  mark('PWA Manifest', Boolean(document.querySelector('link[rel="manifest"]')));

  const markupHints = [];
  for (const attribute of Array.from(document.documentElement.attributes)) {
    if (attribute.name.startsWith('data-') || attribute.name === 'class') {
      markupHints.push(`${attribute.name}=${attribute.value}`.slice(0, 180));
    }
  }
  if (document.body?.className && typeof document.body.className === 'string') {
    markupHints.push(`body.class=${document.body.className}`.slice(0, 180));
  }
  const hasModulePreloads = Boolean(document.querySelector('link[rel="modulepreload"]'));
  const hasHashedEntry = scriptAssets.some((item) =>
    /\/assets\/(?:index|main|app)-[A-Za-z0-9_-]{6,}\.js(?:\?|$)/.test(item.url)
  );
  if (hasModulePreloads && hasHashedEntry) {
    markupHints.push('build=vite-build-assets');
  }

  return {
    page_title: document.title || '',
    meta_description: document.querySelector('meta[name="description"]')?.content || document.querySelector('meta[property="og:description"]')?.content || '',
    seo: {
      title: document.title || '',
      meta_description: metaBy('meta[name="description"]') || metaBy('meta[property="og:description"]'),
      canonical: document.querySelector('link[rel="canonical"]')?.href || '',
      language: document.documentElement.lang || '',
      robots: metaBy('meta[name="robots"]'),
      open_graph: allMeta('property').filter((item) => item.name.startsWith('og:')),
      twitter: allMeta('name').filter((item) => item.name.startsWith('twitter:')),
      json_ld: Array.from(document.querySelectorAll('script[type="application/ld+json"]')).map((el) => (el.textContent || '').trim()).filter(Boolean).slice(0, 20),
      headings,
      internal_links: links.filter((link) => !link.external).length,
      external_links: links.filter((link) => link.external).length,
    },
    assets: {
      images: imgAssets,
      icons: iconAssets,
      stylesheets: styleAssets,
      scripts: scriptAssets,
    },
    accessibility: {
      missing_alt_images: missingAltImages,
      empty_buttons: emptyButtons,
      unlabeled_inputs: unlabeledInputs,
      heading_skips: headingSkips.slice(0, 40),
    },
    css_variables: cssVariables.slice(0, 160),
    structure: {
      h1: Array.from(document.querySelectorAll('h1')).map(textOf).filter(Boolean).slice(0, 8),
      h2: Array.from(document.querySelectorAll('h2')).map(textOf).filter(Boolean).slice(0, 16),
      links: document.querySelectorAll('a').length,
      buttons: document.querySelectorAll('button, [role="button"]').length,
      images: document.querySelectorAll('img').length,
      svgs: document.querySelectorAll('svg').length,
      forms: document.querySelectorAll('form').length,
    },
    observed_colors: Array.from(colorSet).slice(0, 32),
    observed_fonts: Array.from(fontSet).slice(0, 16),
    element_samples: samples,
    responsive_issues: responsiveIssues.slice(0, 40),
    _technology_signals: {
      generator: metaBy('meta[name="generator"], meta[property="generator"]'),
      runtime_markers: runtimeMarkers,
      script_urls: scriptAssets.map((item) => item.url).slice(0, 80),
      stylesheet_urls: styleAssets.map((item) => item.url).slice(0, 80),
      markup_hints: markupHints.slice(0, 20),
      generic_signals: {
        same_origin_script_count: sameOriginScripts.length,
        same_origin_stylesheet_count: sameOriginStylesheets.length,
        module_script_count: moduleScripts.length,
        semantic_content_element_count: document.querySelectorAll(
          'main, article, section, h1, h2, h3, p, ul, ol'
        ).length,
        self_hosted_font_count: selfHostedFontUrls.length,
      },
    },
  };
}
"""

DOCUMENT_HEIGHT_JS = (
    "Math.max(document.body?.scrollHeight || 0, "
    "document.documentElement?.scrollHeight || 0)"
)
MARK_NAVIGATION_CONTROL_JS = "el => el.setAttribute('data-gyrus-navigation-inspected', 'true')"


def extractor_arguments(viewport: dict[str, Any], *, is_touch: bool) -> dict[str, Any]:
    """The argument VISUAL_EXTRACTOR_JS receives as ``inspection``."""
    return {"is_touch": is_touch, "expected_width": viewport["width"]}


def split_extraction(raw: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any] | None]:
    """Separate the viewport document from the private technology signals.

    Mutates and returns ``raw`` so the key order the extractor produced is
    preserved in the stored document. Navigation is captured once per run on
    the snapshot, never per viewport.
    """
    raw.pop("navigation", None)
    signals = raw.pop("_technology_signals", None)
    return raw, signals
