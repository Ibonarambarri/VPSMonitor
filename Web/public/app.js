const PAGES = new Set(["summary", "projects", "alerts", "settings"]);
const PAGE_TITLES = {
  summary: "Resumen",
  projects: "Proyectos",
  alerts: "Alertas",
  settings: "Ajustes"
};

const STATUS = {
  healthy: { label: "Todo correcto", compact: "Disponible", symbol: "✓" },
  warning: { label: "Requiere atención", compact: "Atención", symbol: "!" },
  critical: { label: "Problema crítico", compact: "Con problemas", symbol: "×" },
  unknown: { label: "Estado desconocido", compact: "Desconocido", symbol: "?" }
};

const state = {
  authenticated: false,
  dashboard: null,
  currentPage: "summary",
  projectFilter: "all",
  projectQuery: "",
  refreshing: false,
  serviceWorkerRegistration: null,
  pushSubscription: null,
  pushBusy: false,
  deferredInstallPrompt: null,
  installCompleted: false,
  toastTimer: null,
  pollTimer: null
};

const dom = {
  connectionBanner: document.querySelector("#connection-banner"),
  loginView: document.querySelector("#login-view"),
  loginForm: document.querySelector("#login-form"),
  password: document.querySelector("#password"),
  loginButton: document.querySelector("#login-button"),
  loginError: document.querySelector("#login-error"),
  appShell: document.querySelector("#app-shell"),
  pageTitle: document.querySelector("#page-title"),
  pageContent: document.querySelector("#page-content"),
  refreshButton: document.querySelector("#refresh-button"),
  globalMessage: document.querySelector("#global-message"),
  globalMessageText: document.querySelector("#global-message-text"),
  globalRetry: document.querySelector("#global-retry"),
  serverName: document.querySelector("#server-name"),
  overallStatus: document.querySelector("#overall-status"),
  generatedAt: document.querySelector("#generated-at"),
  serverAvailability: document.querySelector("#server-availability"),
  cpuCard: document.querySelector("#cpu-card"),
  cpuValue: document.querySelector("#cpu-value"),
  cpuChart: document.querySelector("#cpu-chart"),
  cpuDescription: document.querySelector("#cpu-description"),
  memoryCard: document.querySelector("#memory-card"),
  memoryValue: document.querySelector("#memory-value"),
  memoryChart: document.querySelector("#memory-chart"),
  memoryDescription: document.querySelector("#memory-description"),
  diskCard: document.querySelector("#disk-card"),
  diskValue: document.querySelector("#disk-value"),
  diskProgress: document.querySelector("#disk-progress"),
  diskDescription: document.querySelector("#disk-description"),
  uptimeCard: document.querySelector("#uptime-card"),
  uptimeValue: document.querySelector("#uptime-value"),
  loadDescription: document.querySelector("#load-description"),
  coolifyStatus: document.querySelector("#coolify-status"),
  projectCount: document.querySelector("#project-count"),
  problemCount: document.querySelector("#problem-count"),
  coolifyButton: document.querySelector("#coolify-button"),
  coolifyHint: document.querySelector("#coolify-hint"),
  alertPreview: document.querySelector("#alert-preview"),
  installCard: document.querySelector("#install-card"),
  projectSearch: document.querySelector("#project-search"),
  projectsSummary: document.querySelector("#projects-summary"),
  projectsList: document.querySelector("#projects-list"),
  alertsList: document.querySelector("#alerts-list"),
  alertBadge: document.querySelector("#alert-badge"),
  settingsServerStatus: document.querySelector("#settings-server-status"),
  settingsCoolifyStatus: document.querySelector("#settings-coolify-status"),
  pushTitle: document.querySelector("#push-title"),
  pushStatus: document.querySelector("#push-status"),
  pushButton: document.querySelector("#push-button"),
  themeSelect: document.querySelector("#theme-select"),
  installStatusTitle: document.querySelector("#install-status-title"),
  installStatus: document.querySelector("#install-status"),
  settingsInstallButton: document.querySelector("#settings-install-button"),
  logoutButton: document.querySelector("#logout-button"),
  installDialog: document.querySelector("#install-dialog"),
  installDialogTitle: document.querySelector("#install-dialog-title"),
  alertDialog: document.querySelector("#alert-dialog"),
  alertDialogTitle: document.querySelector("#alert-dialog-title"),
  alertDialogSource: document.querySelector("#alert-dialog-source"),
  alertDialogSeverity: document.querySelector("#alert-dialog-severity"),
  alertDialogMessage: document.querySelector("#alert-dialog-message"),
  alertDialogTime: document.querySelector("#alert-dialog-time"),
  toast: document.querySelector("#toast"),
  skipLink: document.querySelector(".skip-link")
};

class APIError extends Error {
  constructor(message, status = 0, payload = null) {
    super(message);
    this.name = "APIError";
    this.status = status;
    this.payload = payload;
  }
}

function bindEvents() {
  dom.loginForm.addEventListener("submit", handleLogin);
  dom.logoutButton.addEventListener("click", handleLogout);
  dom.refreshButton.addEventListener("click", () => refreshDashboard(true));
  dom.globalRetry.addEventListener("click", () => refreshDashboard(true));
  dom.projectSearch.addEventListener("input", () => {
    state.projectQuery = dom.projectSearch.value.trim().toLocaleLowerCase("es");
    renderProjects();
  });

  document.querySelectorAll("[data-project-filter]").forEach((button) => {
    button.addEventListener("click", () => {
      state.projectFilter = button.dataset.projectFilter;
      document.querySelectorAll("[data-project-filter]").forEach((item) => {
        item.setAttribute("aria-pressed", String(item === button));
      });
      renderProjects();
    });
  });

  document.querySelectorAll("[data-install]").forEach((button) => {
    button.addEventListener("click", handleInstallRequest);
  });

  document.querySelectorAll("[data-close-dialog]").forEach((button) => {
    button.addEventListener("click", () => closeDialog(button.closest("dialog")));
  });

  [dom.installDialog, dom.alertDialog].forEach((dialog) => {
    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) closeDialog(dialog);
    });
  });

  dom.coolifyButton.addEventListener("click", (event) => {
    if (dom.coolifyButton.getAttribute("aria-disabled") === "true") {
      event.preventDefault();
      showToast("Coolify no tiene una URL HTTPS configurada.");
      return;
    }
    showToast("Abriendo Coolify fuera de VPS Monitor…");
  });

  dom.pushButton.addEventListener("click", handlePushAction);
  dom.themeSelect.addEventListener("change", () => applyTheme(dom.themeSelect.value, true));
  window.addEventListener("hashchange", () => applyRoute(true));
  window.addEventListener("online", handleConnectionChange);
  window.addEventListener("offline", handleConnectionChange);
  window.addEventListener("appinstalled", () => {
    state.deferredInstallPrompt = null;
    state.installCompleted = true;
    updateInstallUI();
    showToast("VPS Monitor se ha añadido al dispositivo.");
  });
  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    state.deferredInstallPrompt = event;
    updateInstallUI();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && state.authenticated && navigator.onLine) {
      const generatedAt = parseDate(state.dashboard?.generatedAt);
      if (!generatedAt || Date.now() - generatedAt.getTime() > 60_000) loadDashboard(false);
    }
  });
  dom.skipLink.addEventListener("click", (event) => {
    event.preventDefault();
    dom.pageContent.focus();
  });
}

async function apiRequest(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body != null && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  let response;
  try {
    response = await fetch(path, {
      ...options,
      headers,
      credentials: "same-origin",
      cache: "no-store"
    });
  } catch {
    throw new APIError("No se pudo conectar con VPS Monitor.");
  }

  let payload = null;
  if (response.status !== 204) {
    const contentType = response.headers.get("content-type") || "";
    try {
      payload = contentType.includes("application/json")
        ? await response.json()
        : await response.text();
    } catch {
      payload = null;
    }
  }

  if (!response.ok) {
    if (response.status === 401 && path !== "/api/login" && path !== "/api/session") {
      showLogin("La sesión ha caducado. Vuelve a entrar.");
    }
    const message = typeof payload === "string"
      ? payload
      : payload?.error || payload?.message || defaultErrorForStatus(response.status);
    throw new APIError(message, response.status, payload);
  }

  return payload;
}

function defaultErrorForStatus(status) {
  if (status === 401) return "La contraseña no es correcta.";
  if (status === 403) return "No tienes permiso para realizar esta acción.";
  if (status === 429) return "Demasiados intentos. Espera un momento.";
  if (status >= 500) return "El servidor no pudo completar la operación.";
  return "No se pudo completar la operación.";
}

async function restoreSession() {
  try {
    const session = await apiRequest("/api/session");
    const authenticated = session == null
      || (session.authenticated ?? session.loggedIn ?? session.ok ?? true) === true;
    if (authenticated) {
      showApp();
      await loadDashboard(false);
    } else {
      showLogin();
    }
  } catch (error) {
    showLogin(error.status === 401 ? "" : error.message);
  }
}

async function handleLogin(event) {
  event.preventDefault();
  const password = dom.password.value;
  if (!password) {
    showLoginError("Introduce la contraseña.");
    dom.password.focus();
    return;
  }

  setButtonBusy(dom.loginButton, true, "Entrando…");
  hideLoginError();
  try {
    await apiRequest("/api/login", {
      method: "POST",
      body: JSON.stringify({ password })
    });
    dom.password.value = "";
    showApp();
    await loadDashboard(false);
    showToast("Sesión iniciada.");
  } catch (error) {
    showLoginError(error.message || "No se pudo iniciar sesión.");
  } finally {
    setButtonBusy(dom.loginButton, false, "Entrar");
  }
}

async function handleLogout() {
  setButtonBusy(dom.logoutButton, true, "Cerrando…");
  try {
    await apiRequest("/api/logout", { method: "POST" });
    showLogin();
    showToast("Sesión cerrada.");
  } catch (error) {
    if (error.status !== 401) showToast(error.message || "No se pudo cerrar la sesión.");
  } finally {
    setButtonBusy(dom.logoutButton, false, "Cerrar sesión");
  }
}

function showApp() {
  state.authenticated = true;
  dom.loginView.hidden = true;
  dom.appShell.hidden = false;
  hideLoginError();
  applyRoute(false);
  updateInstallUI();
  updatePushUI();
  void synchronizePushSubscription();
  startPolling();
}

function showLogin(message = "") {
  state.authenticated = false;
  state.dashboard = null;
  dom.appShell.hidden = true;
  dom.loginView.hidden = false;
  dom.globalMessage.hidden = true;
  stopPolling();
  if (message) showLoginError(message);
  else hideLoginError();
}

function showLoginError(message) {
  dom.loginError.textContent = message;
  dom.loginError.hidden = !message;
}

function hideLoginError() {
  dom.loginError.textContent = "";
  dom.loginError.hidden = true;
}

async function loadDashboard(announce = false) {
  if (!state.authenticated || state.refreshing) return;
  const initialLoad = !state.dashboard;
  if (initialLoad) dom.pageContent.classList.add("dashboard-loading");
  dom.pageContent.setAttribute("aria-busy", "true");
  try {
    const dashboard = await apiRequest("/api/dashboard");
    if (!isDashboardPayload(dashboard)) throw new APIError("El servidor devolvió un panel no válido.");
    state.dashboard = dashboard;
    renderDashboard();
    if (announce) showToast("Datos actualizados.");
  } catch (error) {
    if (error.status !== 401) showGlobalMessage(error.message || "No se pudieron cargar los datos.");
  } finally {
    dom.pageContent.classList.remove("dashboard-loading");
    dom.pageContent.setAttribute("aria-busy", "false");
  }
}

async function refreshDashboard(announce = true) {
  if (!state.authenticated || state.refreshing) return;
  state.refreshing = true;
  dom.refreshButton.disabled = true;
  dom.refreshButton.classList.add("is-loading");
  dom.refreshButton.setAttribute("aria-busy", "true");
  try {
    const result = await apiRequest("/api/refresh", { method: "POST" });
    const dashboard = isDashboardPayload(result)
      ? result
      : isDashboardPayload(result?.dashboard)
        ? result.dashboard
        : await apiRequest("/api/dashboard");
    if (!isDashboardPayload(dashboard)) throw new APIError("El servidor devolvió un panel no válido.");
    state.dashboard = dashboard;
    renderDashboard();
    if (announce) showToast("Comprobación completada.");
  } catch (error) {
    if (error.status !== 401) {
      showGlobalMessage(error.message || "No se pudo actualizar.");
      showToast("La actualización ha fallado.");
    }
  } finally {
    state.refreshing = false;
    dom.refreshButton.disabled = false;
    dom.refreshButton.classList.remove("is-loading");
    dom.refreshButton.removeAttribute("aria-busy");
  }
}

function isDashboardPayload(value) {
  return Boolean(value && typeof value === "object" && value.server && value.coolify && Array.isArray(value.alerts));
}

function renderDashboard() {
  const dashboard = state.dashboard;
  if (!dashboard) return;
  renderServer(dashboard.server || {}, dashboard.overallState, dashboard.generatedAt);
  renderCoolify(dashboard.coolify || {});
  renderProjects();
  renderAlerts();
  renderConnections();
  renderDashboardErrors(dashboard.errors);
  updateInstallUI();
}

function renderServer(server, overallState, generatedAt) {
  const available = server.available === true;
  const normalizedOverall = normalizeState(overallState || (available ? "healthy" : "critical"));
  dom.serverName.textContent = nonEmptyString(server.name) || "Servidor sin nombre";
  setStatus(dom.overallStatus, normalizedOverall);
  dom.serverAvailability.textContent = available ? "Disponible" : "No disponible";
  dom.serverAvailability.className = `availability-label state-${available ? "healthy" : "critical"}`;

  const generatedDate = parseDate(generatedAt);
  dom.generatedAt.dataset.timestamp = generatedDate ? generatedDate.toISOString() : "";
  updateGeneratedAtLabel();

  const cpu = available ? finiteNumber(server.cpuPercent) : null;
  const memoryPercent = available
    ? percentage(server.memoryUsedBytes, server.memoryTotalBytes)
    : null;
  const diskPercent = available
    ? percentage(server.diskUsedBytes, server.diskTotalBytes)
    : null;

  dom.cpuValue.textContent = formatPercent(cpu);
  dom.cpuDescription.textContent = cpu == null ? "Sin datos" : describeUsage(cpu);
  dom.cpuCard.setAttribute("aria-label", `CPU: ${cpu == null ? "sin datos" : `${formatPercent(cpu)}, ${describeUsage(cpu)}`}`);
  renderSparkline(dom.cpuChart, server.history, "cpuPercent");

  dom.memoryValue.textContent = formatPercent(memoryPercent);
  dom.memoryDescription.textContent = memoryPercent == null
    ? "Sin datos"
    : `${formatBytes(server.memoryUsedBytes)} de ${formatBytes(server.memoryTotalBytes)}`;
  dom.memoryCard.setAttribute("aria-label", `RAM: ${memoryPercent == null ? "sin datos" : `${formatPercent(memoryPercent)}, ${dom.memoryDescription.textContent}`}`);
  renderSparkline(dom.memoryChart, server.history, "memoryPercent");

  dom.diskValue.textContent = formatPercent(diskPercent);
  dom.diskDescription.textContent = diskPercent == null
    ? "Sin datos"
    : `${formatBytes(server.diskUsedBytes)} de ${formatBytes(server.diskTotalBytes)}`;
  dom.diskCard.setAttribute("aria-label", `Disco: ${diskPercent == null ? "sin datos" : `${formatPercent(diskPercent)}, ${dom.diskDescription.textContent}`}`);
  setProgress(dom.diskProgress, diskPercent);

  const uptime = available ? finiteNumber(server.uptimeSeconds) : null;
  dom.uptimeValue.textContent = formatDuration(uptime);
  dom.loadDescription.textContent = available ? formatLoad(server) : "Carga —";
  dom.uptimeCard.setAttribute("aria-label", `Uptime: ${formatDuration(uptime)}. ${dom.loadDescription.textContent}`);
}

function renderCoolify(coolify) {
  const projects = Array.isArray(coolify.projects) ? coolify.projects : [];
  const available = coolify.available === true;
  const issues = projects.filter((project) => ["warning", "critical"].includes(projectState(project))).length;
  const coolifyState = available ? (issues > 0 ? "warning" : "healthy") : "critical";

  dom.coolifyStatus.className = `compact-status status-${coolifyState}`;
  dom.coolifyStatus.textContent = available ? STATUS[coolifyState].compact : "No disponible";
  dom.projectCount.textContent = available ? String(projects.length) : "—";
  dom.problemCount.textContent = available ? String(issues) : "—";

  const dashboardURL = validHTTPSURL(coolify.dashboardUrl);
  if (dashboardURL) {
    dom.coolifyButton.href = dashboardURL;
    dom.coolifyButton.target = "_blank";
    dom.coolifyButton.rel = "noopener noreferrer";
    dom.coolifyButton.referrerPolicy = "no-referrer";
    dom.coolifyButton.setAttribute("aria-disabled", "false");
    dom.coolifyButton.setAttribute("aria-label", "Abrir Coolify fuera de VPS Monitor");
    dom.coolifyButton.removeAttribute("tabindex");
    dom.coolifyHint.textContent = available
      ? "Se abrirá fuera de VPS Monitor."
      : "Coolify no responde, pero puedes intentar abrirlo.";
  } else {
    dom.coolifyButton.removeAttribute("href");
    dom.coolifyButton.removeAttribute("target");
    dom.coolifyButton.setAttribute("aria-disabled", "true");
    dom.coolifyButton.setAttribute("tabindex", "0");
    dom.coolifyHint.textContent = "Se necesita una URL HTTPS válida.";
  }
}

function renderProjects() {
  dom.projectsList.replaceChildren();
  const coolify = state.dashboard?.coolify;
  const allProjects = Array.isArray(coolify?.projects) ? coolify.projects : [];

  if (coolify?.available !== true) {
    dom.projectsSummary.textContent = "";
    dom.projectsList.append(createEmptyState("Coolify no disponible", "No se pueden consultar los proyectos ahora mismo."));
    return;
  }

  const projects = allProjects.filter((project) => {
    const matchesQuery = !state.projectQuery
      || String(project?.name || "").toLocaleLowerCase("es").includes(state.projectQuery);
    const matchesFilter = state.projectFilter !== "issues"
      || ["warning", "critical"].includes(projectState(project));
    return matchesQuery && matchesFilter;
  });

  dom.projectsSummary.textContent = `${projects.length} de ${allProjects.length} proyectos`;
  if (projects.length === 0) {
    const title = allProjects.length === 0 ? "Sin proyectos" : "Sin resultados";
    const copy = allProjects.length === 0
      ? "Coolify no ha devuelto ningún proyecto."
      : "Prueba otra búsqueda o cambia el filtro.";
    dom.projectsList.append(createEmptyState(title, copy));
    return;
  }

  projects.forEach((project) => dom.projectsList.append(createProjectCard(project)));
}

function createProjectCard(project) {
  const details = element("details", "project-card");
  const summary = element("summary");
  const health = projectState(project);
  const resources = projectResources(project);
  const issues = resources.filter((resource) => ["warning", "critical"].includes(normalizeState(resource?.state || resource?.status))).length;

  const dot = element("span", `project-status-dot state-${health}`);
  dot.setAttribute("aria-hidden", "true");
  const copy = element("span", "project-summary-copy");
  copy.append(
    element("strong", "", nonEmptyString(project?.name) || "Proyecto"),
    element("span", "", `${resources.length} recursos${issues ? ` · ${issues} con problemas` : ""}`)
  );
  const chevron = element("span", "disclosure-chevron", "›");
  chevron.setAttribute("aria-hidden", "true");
  summary.append(dot, copy, chevron);
  summary.setAttribute("aria-label", `${nonEmptyString(project?.name) || "Proyecto"}, ${STATUS[health].label}, ${resources.length} recursos`);

  const environments = element("div", "environment-list");
  const projectEnvironments = Array.isArray(project?.environments) ? project.environments : [];
  if (projectEnvironments.length === 0) {
    environments.append(createEmptyState("Sin entornos", "Este proyecto no contiene entornos visibles."));
  } else {
    projectEnvironments.forEach((environment) => environments.append(createEnvironment(environment)));
  }
  details.append(summary, environments);
  return details;
}

function createEnvironment(environment) {
  const section = element("section", "environment");
  const heading = element("h3", "", nonEmptyString(environment?.name) || "Entorno");
  const list = element("div", "resource-list");
  const resources = Array.isArray(environment?.resources) ? environment.resources : [];
  if (resources.length === 0) {
    list.append(element("div", "resource-row", "Sin recursos"));
  } else {
    resources.forEach((resource) => list.append(createResourceRow(resource)));
  }
  section.append(heading, list);
  return section;
}

function createResourceRow(resource) {
  const row = element("div", "resource-row");
  const health = normalizeState(resource?.state || resource?.status);
  const dot = element("span", `resource-status-dot state-${health}`);
  dot.setAttribute("aria-hidden", "true");
  const copy = element("span", "resource-copy");
  copy.append(
    element("strong", "", nonEmptyString(resource?.name) || "Recurso"),
    element("span", "", nonEmptyString(resource?.type) || "Recurso")
  );
  const trailing = element("span", "resource-trailing");
  trailing.append(element("span", "resource-state", nonEmptyString(resource?.status) || STATUS[health].compact));
  const url = validHTTPSURL(resource?.url);
  if (url) {
    const link = element("a", "resource-link");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.referrerPolicy = "no-referrer";
    link.setAttribute("aria-label", `Abrir ${nonEmptyString(resource?.name) || "recurso"} fuera de VPS Monitor`);
    link.textContent = "↗";
    trailing.append(link);
  }
  row.append(dot, copy, trailing);
  return row;
}

function renderAlerts() {
  const alerts = Array.isArray(state.dashboard?.alerts) ? state.dashboard.alerts : [];
  dom.alertPreview.replaceChildren();
  dom.alertsList.replaceChildren();

  if (alerts.length === 0) {
    dom.alertPreview.append(createEmptyState("Sin alertas activas", "No hay incidencias que requieran atención."));
    dom.alertsList.append(createEmptyState("Todo tranquilo", "Las alertas aparecerán aquí cuando el monitor detecte una incidencia."));
  } else {
    alerts.slice(0, 2).forEach((alert) => dom.alertPreview.append(createAlertRow(alert)));
    alerts.forEach((alert) => dom.alertsList.append(createAlertRow(alert)));
  }

  const count = alerts.length;
  dom.alertBadge.hidden = count === 0;
  dom.alertBadge.textContent = count > 99 ? "99+" : String(count);
  updateAppBadge(count);
}

function createAlertRow(alert) {
  const button = element("button", "alert-row");
  button.type = "button";
  const severity = normalizeAlertSeverity(alert?.severity);
  const meta = STATUS[severity];
  const indicator = element("span", `alert-indicator status-${severity}`, meta.symbol);
  indicator.setAttribute("aria-hidden", "true");
  const copy = element("span", "alert-copy");
  copy.append(
    element("strong", "", nonEmptyString(alert?.title) || "Alerta"),
    element("span", "", alertSummary(alert))
  );
  const chevron = element("span", "row-chevron", "›");
  chevron.setAttribute("aria-hidden", "true");
  button.append(indicator, copy, chevron);
  button.setAttribute("aria-label", `${nonEmptyString(alert?.title) || "Alerta"}, ${meta.label}, ${alertSummary(alert)}`);
  button.addEventListener("click", () => openAlertDialog(alert));
  return button;
}

function openAlertDialog(alert) {
  const severity = normalizeAlertSeverity(alert?.severity);
  dom.alertDialogTitle.textContent = nonEmptyString(alert?.title) || "Detalle de alerta";
  dom.alertDialogSource.textContent = nonEmptyString(alert?.source) || "VPS Monitor";
  dom.alertDialogMessage.textContent = nonEmptyString(alert?.message) || "No hay más información disponible.";
  dom.alertDialogTime.textContent = formatDateTime(alert?.observedAt);
  setStatus(dom.alertDialogSeverity, severity);
  openDialog(dom.alertDialog);
}

function renderConnections() {
  const serverAvailable = state.dashboard?.server?.available === true;
  const coolifyAvailable = state.dashboard?.coolify?.available === true;
  dom.settingsServerStatus.textContent = serverAvailable ? "Disponible" : "No disponible";
  dom.settingsServerStatus.className = `settings-value state-${serverAvailable ? "healthy" : "critical"}`;
  dom.settingsCoolifyStatus.textContent = coolifyAvailable ? "Disponible" : "No disponible";
  dom.settingsCoolifyStatus.className = `settings-value state-${coolifyAvailable ? "healthy" : "critical"}`;
}

function renderDashboardErrors(errors) {
  const messages = Array.isArray(errors)
    ? errors.filter((message) => typeof message === "string" && message.trim()).map((message) => message.trim())
    : [];
  if (messages.length === 0) {
    hideGlobalMessage();
    return;
  }
  showGlobalMessage(messages.join(" · "));
}

function showGlobalMessage(message) {
  dom.globalMessageText.textContent = message;
  dom.globalMessage.hidden = false;
}

function hideGlobalMessage() {
  dom.globalMessageText.textContent = "";
  dom.globalMessage.hidden = true;
}

function renderSparkline(svg, history, key) {
  svg.replaceChildren();
  const samples = (Array.isArray(history) ? history : [])
    .map((sample) => finiteNumber(sample?.[key]))
    .filter((value) => value != null);
  if (samples.length < 2) {
    svg.hidden = true;
    return;
  }

  svg.hidden = false;
  const width = 160;
  const height = 44;
  const padding = 2;
  const points = samples.map((value, index) => {
    const x = padding + (index / (samples.length - 1)) * (width - padding * 2);
    const y = height - padding - (clamp(value, 0, 100) / 100) * (height - padding * 2);
    return [Number(x.toFixed(2)), Number(y.toFixed(2))];
  });
  const pointText = points.map(([x, y]) => `${x},${y}`).join(" ");
  const namespace = "http://www.w3.org/2000/svg";
  const area = document.createElementNS(namespace, "path");
  area.setAttribute("class", "sparkline-area");
  area.setAttribute("d", `M ${points[0][0]},${height} L ${pointText.replaceAll(" ", " L ")} L ${points.at(-1)[0]},${height} Z`);
  const line = document.createElementNS(namespace, "polyline");
  line.setAttribute("class", "sparkline-line");
  line.setAttribute("points", pointText);
  svg.append(area, line);
}

function setProgress(elementToUpdate, value) {
  const percent = value == null ? 0 : clamp(value, 0, 100);
  elementToUpdate.value = percent;
  elementToUpdate.setAttribute("aria-valuetext", value == null ? "Sin datos" : formatPercent(percent));
  elementToUpdate.classList.toggle("is-warning", percent >= 80 && percent < 90);
  elementToUpdate.classList.toggle("is-critical", percent >= 90);
}

function applyRoute(moveFocus) {
  const hash = window.location.hash;
  const requested = hash.startsWith("#/") ? hash.slice(2).split("/")[0] : "";
  const page = PAGES.has(requested) ? requested : state.currentPage || "summary";
  state.currentPage = page;
  document.querySelectorAll("[data-page]").forEach((section) => {
    section.hidden = section.dataset.page !== page;
  });
  document.querySelectorAll("[data-route]").forEach((link) => {
    if (link.dataset.route === page) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
  dom.pageTitle.textContent = PAGE_TITLES[page];
  document.title = `${PAGE_TITLES[page]} · VPS Monitor`;
  if (moveFocus && state.authenticated) {
    window.scrollTo({ top: 0, behavior: prefersReducedMotion() ? "auto" : "smooth" });
    dom.pageTitle.tabIndex = -1;
    dom.pageTitle.focus({ preventScroll: true });
  }
}

function startPolling() {
  stopPolling();
  state.pollTimer = window.setInterval(() => {
    if (state.authenticated && navigator.onLine && document.visibilityState === "visible") {
      loadDashboard(false);
    }
  }, 60_000);
}

function stopPolling() {
  if (state.pollTimer) window.clearInterval(state.pollTimer);
  state.pollTimer = null;
}

function handleConnectionChange(event) {
  dom.connectionBanner.hidden = navigator.onLine;
  if (navigator.onLine) {
    if (event?.type === "online") showToast("Conexión recuperada.");
    if (state.authenticated) loadDashboard(false);
  }
}

function setupInstallation() {
  updateInstallUI();
}

async function handleInstallRequest() {
  if (isInstalled()) {
    showToast("VPS Monitor ya está instalado.");
    return;
  }
  if (state.deferredInstallPrompt) {
    state.deferredInstallPrompt.prompt();
    await state.deferredInstallPrompt.userChoice;
    state.deferredInstallPrompt = null;
    updateInstallUI();
    return;
  }
  openDialog(dom.installDialog);
}

function updateInstallUI() {
  const installed = isInstalled();
  dom.installCard.hidden = installed || !state.authenticated;
  dom.installStatusTitle.textContent = installed ? "Aplicación instalada" : "Añadir al iPhone";
  dom.installStatus.textContent = installed
    ? "Se está ejecutando desde la pantalla de inicio."
    : "Ábrela sin las barras del navegador.";
  dom.settingsInstallButton.disabled = installed;
  dom.settingsInstallButton.textContent = installed ? "Instalada" : "Ver pasos";
}

function isInstalled() {
  return state.installCompleted || isStandalone();
}

function isStandalone() {
  return window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true;
}

function isIOS() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent)
    || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

async function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) {
    updatePushUI();
    return;
  }
  try {
    await navigator.serviceWorker.register("/sw.js", { scope: "/" });
    state.serviceWorkerRegistration = await navigator.serviceWorker.ready;
    await refreshPushSubscription();
    await synchronizePushSubscription();
  } catch {
    state.serviceWorkerRegistration = null;
    updatePushUI();
  }
}

async function refreshPushSubscription() {
  if (!state.serviceWorkerRegistration || !("pushManager" in state.serviceWorkerRegistration)) {
    state.pushSubscription = null;
  } else {
    state.pushSubscription = await state.serviceWorkerRegistration.pushManager.getSubscription();
  }
  updatePushUI();
}

async function synchronizePushSubscription() {
  if (!state.authenticated || !state.pushSubscription) return;
  try {
    await apiRequest("/api/push/subscribe", {
      method: "POST",
      body: JSON.stringify(state.pushSubscription.toJSON
        ? state.pushSubscription.toJSON()
        : state.pushSubscription)
    });
  } catch {
    // The subscription remains local and will be retried after the next session restore.
  }
}

async function handlePushAction() {
  if (state.pushBusy) return;
  if (isIOS() && !isStandalone()) {
    showToast("Añade VPS Monitor a la pantalla de inicio para activar notificaciones.");
    openDialog(dom.installDialog);
    return;
  }
  if (!supportsPush()) {
    showToast("Este navegador no admite notificaciones push.");
    return;
  }

  state.pushBusy = true;
  setButtonBusy(dom.pushButton, true, state.pushSubscription ? "Desactivando…" : "Activando…");
  try {
    if (state.pushSubscription) await disablePush();
    else await enablePush();
    await refreshPushSubscription();
  } catch (error) {
    showToast(error.message || "No se pudieron cambiar las notificaciones.");
  } finally {
    state.pushBusy = false;
    setButtonBusy(dom.pushButton, false, "");
    updatePushUI();
  }
}

async function enablePush() {
  const keyResponse = await apiRequest("/api/push/key");
  const publicKey = extractPushKey(keyResponse);
  if (!publicKey) throw new APIError("Las notificaciones push no están configuradas en el servidor.");

  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    updatePushUI();
    throw new APIError(permission === "denied"
      ? "Las notificaciones están bloqueadas en el sistema."
      : "No se concedió permiso para notificaciones.");
  }

  const subscription = await state.serviceWorkerRegistration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: base64URLToUint8Array(publicKey)
  });
  try {
    await apiRequest("/api/push/subscribe", {
      method: "POST",
      body: JSON.stringify(subscription.toJSON ? subscription.toJSON() : subscription)
    });
  } catch (error) {
    await subscription.unsubscribe().catch(() => {});
    throw error;
  }
  state.pushSubscription = subscription;
  showToast("Notificaciones activadas.");
}

async function disablePush() {
  const subscription = state.pushSubscription;
  if (!subscription) return;
  await apiRequest("/api/push/subscribe", {
    method: "DELETE",
    body: JSON.stringify({ endpoint: subscription.endpoint })
  });
  await subscription.unsubscribe();
  state.pushSubscription = null;
  showToast("Notificaciones desactivadas.");
}

function updatePushUI() {
  const label = dom.pushButton.querySelector(".button-label");
  if (!supportsPush()) {
    dom.pushStatus.textContent = "No compatibles con este navegador.";
    label.textContent = "No disponible";
    dom.pushButton.disabled = true;
    return;
  }
  if (isIOS() && !isStandalone()) {
    dom.pushStatus.textContent = "Instala la app para poder activarlas.";
    label.textContent = "Instalar";
    dom.pushButton.disabled = false;
    return;
  }
  if (Notification.permission === "denied") {
    dom.pushStatus.textContent = "Bloqueadas en los ajustes del sistema.";
    label.textContent = "Bloqueadas";
    dom.pushButton.disabled = true;
    return;
  }
  if (state.pushSubscription) {
    dom.pushStatus.textContent = "Recibirás avisos genéricos de nuevas alertas.";
    label.textContent = "Desactivar";
    dom.pushButton.disabled = state.pushBusy;
    return;
  }
  dom.pushStatus.textContent = "Avisos sin datos sensibles en la pantalla bloqueada.";
  label.textContent = "Activar";
  dom.pushButton.disabled = state.pushBusy;
}

function supportsPush() {
  return Boolean(
    state.serviceWorkerRegistration
    && "Notification" in window
    && "PushManager" in window
    && "pushManager" in state.serviceWorkerRegistration
  );
}

function extractPushKey(payload) {
  if (typeof payload === "string") return payload;
  if (!payload || typeof payload !== "object") return "";
  return payload.publicKey || payload.key || payload.vapidPublicKey || "";
}

function base64URLToUint8Array(value) {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const base64 = (value + padding).replaceAll("-", "+").replaceAll("_", "/");
  const raw = window.atob(base64);
  return Uint8Array.from(raw, (character) => character.charCodeAt(0));
}

function applyTheme(theme, persist = false) {
  const selected = ["light", "dark"].includes(theme) ? theme : "system";
  if (selected === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.dataset.theme = selected;
  dom.themeSelect.value = selected;
  if (persist) {
    try { localStorage.setItem("vpsmonitor-theme", selected); } catch { /* Preferences are optional. */ }
  }
}

function loadTheme() {
  let theme = "system";
  try { theme = localStorage.getItem("vpsmonitor-theme") || "system"; } catch { /* Preferences are optional. */ }
  applyTheme(theme);
}

function setStatus(container, value) {
  const normalized = normalizeState(value);
  const meta = STATUS[normalized];
  container.className = `status-pill status-${normalized}`;
  const symbol = container.querySelector(".status-symbol");
  const label = container.querySelector(".status-label");
  if (symbol) symbol.textContent = meta.symbol;
  if (label) label.textContent = meta.label;
}

function normalizeState(value) {
  const stateValue = String(value || "").toLocaleLowerCase("en");
  if (["critical", "error", "failed", "failure", "down", "offline", "unavailable"].some((token) => stateValue.includes(token))
    || stateValue.includes("unhealthy") || stateValue.includes("stopped") || stateValue.includes("exited")) return "critical";
  if (["warning", "warn", "degraded", "starting", "restarting", "partial"].some((token) => stateValue.includes(token))) return "warning";
  if (["healthy", "ok", "running", "available", "online", "success"].some((token) => stateValue.includes(token))) return "healthy";
  return "unknown";
}

function normalizeAlertSeverity(value) {
  const normalized = normalizeState(value);
  if (normalized !== "unknown") return normalized;
  const severity = String(value || "").toLocaleLowerCase("en");
  if (["high", "fatal", "emergency"].some((token) => severity.includes(token))) return "critical";
  if (["medium", "notice"].some((token) => severity.includes(token))) return "warning";
  return "unknown";
}

function projectResources(project) {
  const environments = Array.isArray(project?.environments) ? project.environments : [];
  return environments.flatMap((environment) => Array.isArray(environment?.resources) ? environment.resources : []);
}

function projectState(project) {
  const states = projectResources(project).map((resource) => normalizeState(resource?.state || resource?.status));
  if (states.includes("critical")) return "critical";
  if (states.includes("warning")) return "warning";
  if (states.length > 0 && states.every((value) => value === "healthy")) return "healthy";
  return "unknown";
}

function alertSummary(alert) {
  const source = nonEmptyString(alert?.source);
  const when = formatRelative(parseDate(alert?.observedAt));
  return [source, when].filter(Boolean).join(" · ") || "Sin detalles";
}

function createEmptyState(title, copy) {
  const container = element("div", "empty-state");
  container.append(element("strong", "", title), element("p", "", copy));
  return container;
}

function element(tagName, className = "", text = null) {
  const node = document.createElement(tagName);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function finiteNumber(value) {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) ? number : null;
}

function percentage(used, total) {
  const usedNumber = finiteNumber(used);
  const totalNumber = finiteNumber(total);
  if (usedNumber == null || totalNumber == null || totalNumber <= 0) return null;
  return clamp(usedNumber / totalNumber * 100, 0, 100);
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function formatPercent(value) {
  return value == null ? "—" : `${Math.round(clamp(value, 0, 100)).toLocaleString("es-ES")}%`;
}

function formatBytes(value) {
  const bytes = finiteNumber(value);
  if (bytes == null || bytes < 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = bytes;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  const digits = index >= 3 && size < 10 ? 1 : 0;
  return `${size.toLocaleString("es-ES", { maximumFractionDigits: digits })} ${units[index]}`;
}

function formatDuration(value) {
  const seconds = finiteNumber(value);
  if (seconds == null || seconds < 0) return "—";
  const totalMinutes = Math.floor(seconds / 60);
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor(totalMinutes % 1440 / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return `${days} d ${hours} h`;
  if (hours > 0) return `${hours} h ${minutes} min`;
  return `${minutes} min`;
}

function formatLoad(server) {
  const values = [server.load1, server.load5, server.load15].map(finiteNumber);
  if (values.some((value) => value == null)) return "Carga —";
  return `Carga ${values.map((value) => value.toLocaleString("es-ES", { maximumFractionDigits: 2 })).join(" · ")}`;
}

function describeUsage(value) {
  if (value >= 90) return "Uso crítico";
  if (value >= 80) return "Uso elevado";
  return "Uso normal";
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function parseDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function formatRelative(date) {
  if (!date) return "";
  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 45) return "ahora";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `hace ${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `hace ${hours} h`;
  const days = Math.round(hours / 24);
  return `hace ${days} d`;
}

function formatDateTime(value) {
  const date = parseDate(value);
  if (!date) return "Hora de detección no disponible";
  return `Detectada el ${new Intl.DateTimeFormat("es-ES", {
    dateStyle: "medium",
    timeStyle: "short"
  }).format(date)}`;
}

function updateGeneratedAtLabel() {
  const date = parseDate(dom.generatedAt.dataset.timestamp);
  if (!date) {
    dom.generatedAt.textContent = "Hora de actualización no disponible";
    return;
  }
  const stale = Date.now() - date.getTime() > 120_000;
  dom.generatedAt.textContent = `Actualizado ${formatRelative(date)}${stale ? " · datos antiguos" : ""}`;
  dom.generatedAt.className = `updated-label${stale ? " state-warning" : ""}`;
  dom.generatedAt.title = new Intl.DateTimeFormat("es-ES", { dateStyle: "medium", timeStyle: "medium" }).format(date);
}

function validHTTPSURL(value) {
  if (typeof value !== "string" || !value.trim()) return "";
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.href : "";
  } catch {
    return "";
  }
}

function setButtonBusy(button, busy, labelText) {
  button.classList.toggle("is-loading", busy);
  button.disabled = busy;
  button.setAttribute("aria-busy", String(busy));
  const label = button.querySelector(".button-label");
  if (label && labelText) label.textContent = labelText;
}

function openDialog(dialog) {
  if (!dialog) return;
  if (typeof dialog.showModal === "function") dialog.showModal();
  else dialog.setAttribute("open", "");
}

function closeDialog(dialog) {
  if (!dialog) return;
  if (typeof dialog.close === "function") dialog.close();
  else dialog.removeAttribute("open");
}

function showToast(message) {
  if (!message) return;
  window.clearTimeout(state.toastTimer);
  dom.toast.textContent = message;
  dom.toast.hidden = false;
  state.toastTimer = window.setTimeout(() => {
    dom.toast.hidden = true;
    dom.toast.textContent = "";
  }, 5000);
}

async function updateAppBadge(count) {
  try {
    if (count > 0 && "setAppBadge" in navigator) await navigator.setAppBadge(count);
    else if (count === 0 && "clearAppBadge" in navigator) await navigator.clearAppBadge();
  } catch {
    // Badging is an optional enhancement.
  }
}

function prefersReducedMotion() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

async function init() {
  loadTheme();
  bindEvents();
  setupInstallation();
  handleConnectionChange();
  registerServiceWorker();
  await restoreSession();
  window.setInterval(updateGeneratedAtLabel, 30_000);
}

init();
