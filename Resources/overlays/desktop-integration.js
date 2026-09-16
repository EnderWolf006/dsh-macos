// DSH desktop integration. Runs before the official module loader boots.
(() => {
  if (location.hostname !== '127.0.0.1' || window.__desktopIntegration) return;
  window.__desktopIntegration = true;
  const post = payload => window.webkit.messageHandlers.dshDesktop.postMessage(payload);
  let localeService;
  let pendingLanguage;
  window.__desktopSetLanguage = language => {
    pendingLanguage = language;
    if (localeService) localeService.setLocale(language);
    return true;
  };
  const installed = new WeakSet();
  function connect(ctx) {
    if (installed.has(ctx)) return;
    installed.add(ctx);
    ctx.inject(['locale'], c => {
      localeService = c.locale;
      if (pendingLanguage) {
        c.locale.setLocale(pendingLanguage);
        pendingLanguage = undefined;
      }
      const sync = () => post({kind: 'language', value: c.locale.getSnapshot().active});
      c.effect(() => c.locale.subscribe(sync));
      sync();
    });
    ctx.inject(['remote', 'sessions'], c => {
      const running = new Set();
      c.remote.$on('api-session/status', (id, active) => {
        if (active) running.add(id);
        else if (running.delete(id)) post({kind: 'completion', id});
      });
      // Waterfall observers must always forward to the actual UI answerer.
      c.remote.$on('approval/request', function(request, next) {
        post({kind: 'permission', id: String(request.callId || c.sessions.scopeOf(this) || '')});
        return next();
      });
      c.remote.$on('user-questions/request', function(request, next) {
        post({kind: 'question', id: String(c.sessions.scopeOf(this) || '')});
        return next();
      });
    });
  }
  function wrap(loader) {
    if (!loader || loader.__desktopWrapped) return loader;
    loader.__desktopWrapped = true;
    let load = loader.load;
    const interceptedLoad = function(definition) {
      if (definition.id === '@deepseek-ai/dsh-api-session-controller') {
        const factory = definition.factory;
        definition = {...definition, factory(...args) {
          const exports = factory(...args);
          const apply = exports.apply;
          return {...exports, apply(ctx, ...rest) {
            connect(ctx);
            return apply(ctx, ...rest);
          }};
        }};
      }
      return load.call(this, definition);
    };
    // DSH replaces loader.load when the queued module system becomes live.
    // Keep interception installed while accepting that implementation swap.
    Object.defineProperty(loader, 'load', {
      configurable: true,
      get: () => interceptedLoad,
      set: value => { load = value; }
    });
    return loader;
  }
  let loader = wrap(window.__ModuleLoader__);
  Object.defineProperty(window, '__ModuleLoader__', {
    configurable: true,
    get: () => loader,
    set: value => { loader = wrap(value); }
  });
})();
