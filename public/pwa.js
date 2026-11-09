(() => {
  const installButton = document.getElementById('pwa-install-button');
  const iosHelp = document.getElementById('pwa-ios-help');
  const isIos = /iPad|iPhone|iPod/.test(navigator.userAgent)
    || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const isStandalone = () => window.matchMedia('(display-mode: standalone)').matches
    || navigator.standalone === true;
  let installPrompt = null;

  const hideInstallControls = () => {
    if (installButton) installButton.hidden = true;
    if (iosHelp) iosHelp.hidden = true;
  };

  if (isStandalone()) {
    hideInstallControls();
  } else if (isIos && iosHelp) {
    iosHelp.hidden = false;
  }

  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault();
    if (isStandalone()) return;
    installPrompt = event;
    if (installButton) installButton.hidden = false;
  });

  window.addEventListener('appinstalled', () => {
    installPrompt = null;
    hideInstallControls();
  });

  installButton?.addEventListener('click', async () => {
    if (!installPrompt) return;
    const prompt = installPrompt;
    installPrompt = null;
    installButton.disabled = true;
    try {
      await prompt.prompt();
      await prompt.userChoice;
    } catch (error) {
      console.error('Could not show the install prompt:', error);
    } finally {
      installButton.disabled = false;
      installButton.hidden = true;
    }
  });

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/service-worker.js', { scope: '/' })
        .catch(error => console.error('Could not register the service worker:', error));
    });
  }
})();
