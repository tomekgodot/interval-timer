"use strict";

/*
  Interval Timer — secure web build

  Security principles used here:
  1. User-controlled strings are never inserted with innerHTML.
  2. No eval(), new Function(), remote scripts, fetch(), or WebSockets.
  3. Saved JSON is parsed inside try/catch and validated before use.
  4. Numeric inputs are bounded to prevent accidental resource exhaustion.
  5. Text lengths and the number of sections/intervals/saved workouts are capped.
*/

const STORAGE_KEY = "intervalTimerWorkouts";
const LIMITS = Object.freeze({
  maxNameLength: 80,
  maxCommandLength: 80,
  maxSections: 50,
  maxIntervalsPerSection: 100,
  maxSectionRepeats: 100,
  maxTrainingRepeats: 100,
  maxIntervalSeconds: 86400,
  maxSavedWorkouts: 100
});

const DEFAULT_TRAINING = [
  { command: "", repeats: 10, intervals: [{ seconds: 10 }, { seconds: 5 }] },
  { command: "", repeats: 1, intervals: [{ seconds: 15 }] },
  { command: "", repeats: 1, intervals: [{ seconds: 30 }] }
];

let training = structuredCloneSafe(DEFAULT_TRAINING);

let currentSection = 0;
let currentInterval = 0;
let currentSectionRepeat = 1;
let currentTrainingRepeat = 1;
let currentTime = 0;

let timerId = null;
let transitionTimeoutId = null;
let audioContext = null;

let totalTrainingSeconds = 0;
let remainingTrainingSeconds = 0;

let running = false;
let paused = false;
let intervalDeadlineMs = 0;
let pausedSecondsLeft = null;
let lastDisplayedSecond = null;
let announcedSectionKey = null;

const els = {};

document.addEventListener("DOMContentLoaded", init);

function init() {
  els.timer = document.getElementById("timer");
  els.remainingTime = document.getElementById("remainingTime");
  els.status = document.getElementById("status");
  els.sections = document.getElementById("sections");
  els.savedWorkouts = document.getElementById("savedWorkouts");
  els.trainingName = document.getElementById("trainingName");
  els.trainingRepeats = document.getElementById("trainingRepeats");

  document.getElementById("startButton").addEventListener("click", startTraining);
  document.getElementById("pauseButton").addEventListener("click", pauseTimer);
  document.getElementById("stopButton").addEventListener("click", stopTimer);
  document.getElementById("saveWorkoutButton").addEventListener("click", saveWorkout);
  document.getElementById("addSectionButton").addEventListener("click", addSection);

  els.trainingRepeats.addEventListener("change", () => {
    els.trainingRepeats.value = String(
      clampInteger(els.trainingRepeats.value, 1, LIMITS.maxTrainingRepeats, 1)
    );
    recalculateIdleTime();
  });

  displayTraining();
  calculateTotalTrainingTime();
  remainingTrainingSeconds = totalTrainingSeconds;
  updateRemainingTime();
  displaySavedWorkouts();

  if ("serviceWorker" in navigator && location.protocol === "https:") {
    navigator.serviceWorker.register("./sw.js").catch(error => {
      console.warn("Service worker registration failed:", error);
    });
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && running && !paused) {
      timerTick();
    }
  });
}

function structuredCloneSafe(value) {
  if (typeof structuredClone === "function") {
    return structuredClone(value);
  }
  return JSON.parse(JSON.stringify(value));
}

function clampInteger(value, min, max, fallback) {
  const number = Number.parseInt(String(value), 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

function cleanText(value, maxLength) {
  return String(value ?? "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trim()
    .slice(0, maxLength);
}

function makeButton(text, className, handler, ariaLabel = "") {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className;
  button.textContent = text;
  if (ariaLabel) button.setAttribute("aria-label", ariaLabel);
  button.addEventListener("click", handler);
  return button;
}

function displayTraining() {
  els.sections.replaceChildren();

  training.forEach((section, sectionIndex) => {
    const sectionDiv = document.createElement("div");
    sectionDiv.className = "section";

    const header = document.createElement("div");
    header.className = "section-header";

    const title = document.createElement("div");
    title.className = "section-title";
    title.textContent = `Sekcja ${sectionIndex + 1}`;

    const repeatBox = document.createElement("div");
    repeatBox.className = "section-repeat";

    const repeatLabel = document.createElement("span");
    repeatLabel.textContent = "Powtórz:";

    const repeatInput = document.createElement("input");
    repeatInput.type = "number";
    repeatInput.min = "1";
    repeatInput.max = String(LIMITS.maxSectionRepeats);
    repeatInput.inputMode = "numeric";
    repeatInput.value = String(section.repeats);
    repeatInput.setAttribute("aria-label", `Powtórzenia sekcji ${sectionIndex + 1}`);
    repeatInput.addEventListener("change", () => {
      changeSectionRepeats(sectionIndex, repeatInput.value);
      repeatInput.value = String(training[sectionIndex].repeats);
    });

    const times = document.createElement("span");
    times.textContent = "razy";

    const deleteSectionButton = makeButton(
      "🗑", "delete",
      () => removeSection(sectionIndex),
      `Usuń sekcję ${sectionIndex + 1}`
    );

    repeatBox.append(repeatLabel, repeatInput, times, deleteSectionButton);
    header.append(title, repeatBox);

    const commandRow = document.createElement("div");
    commandRow.className = "section-command";

    const commandLabel = document.createElement("label");
    const commandId = `section-command-${sectionIndex}`;
    commandLabel.htmlFor = commandId;
    commandLabel.textContent = "Komenda:";

    const commandInput = document.createElement("input");
    commandInput.id = commandId;
    commandInput.type = "text";
    commandInput.maxLength = LIMITS.maxCommandLength;
    commandInput.autocomplete = "off";
    commandInput.placeholder = "np. Pompki";
    commandInput.value = section.command;
    commandInput.addEventListener("change", () => {
      changeSectionCommand(sectionIndex, commandInput.value);
      commandInput.value = training[sectionIndex].command;
    });

    commandRow.append(commandLabel, commandInput);

    const intervalContainer = document.createElement("div");

    section.intervals.forEach((interval, intervalIndex) => {
      const row = document.createElement("div");
      row.className = "interval";

      const number = document.createElement("div");
      number.className = "interval-number";
      number.textContent = `${intervalIndex + 1}.`;

      const secondsInput = document.createElement("input");
      secondsInput.type = "number";
      secondsInput.min = "1";
      secondsInput.max = String(LIMITS.maxIntervalSeconds);
      secondsInput.inputMode = "numeric";
      secondsInput.value = String(interval.seconds);
      secondsInput.setAttribute(
        "aria-label",
        `Czas interwału ${intervalIndex + 1} w sekcji ${sectionIndex + 1}`
      );
      secondsInput.addEventListener("change", () => {
        changeInterval(sectionIndex, intervalIndex, secondsInput.value);
        secondsInput.value = String(training[sectionIndex].intervals[intervalIndex].seconds);
      });

      const suffix = document.createElement("span");
      suffix.textContent = "sek.";

      const deleteIntervalButton = makeButton(
        "🗑", "delete",
        () => removeInterval(sectionIndex, intervalIndex),
        `Usuń interwał ${intervalIndex + 1} w sekcji ${sectionIndex + 1}`
      );

      row.append(number, secondsInput, suffix, deleteIntervalButton);
      intervalContainer.appendChild(row);
    });

    const addIntervalButton = makeButton(
      "＋ DODAJ INTERWAŁ",
      "add",
      () => addInterval(sectionIndex)
    );

    sectionDiv.append(header, commandRow, intervalContainer, addIntervalButton);
    els.sections.appendChild(sectionDiv);
  });
}

function changeSectionCommand(sectionIndex, value) {
  const section = training[sectionIndex];
  if (!section) return;
  section.command = cleanText(value, LIMITS.maxCommandLength);
}

function changeInterval(sectionIndex, intervalIndex, value) {
  const interval = training[sectionIndex]?.intervals?.[intervalIndex];
  if (!interval) return;
  interval.seconds = clampInteger(value, 1, LIMITS.maxIntervalSeconds, 1);
  recalculateIdleTime();
}

function addInterval(sectionIndex) {
  const section = training[sectionIndex];
  if (!section || section.intervals.length >= LIMITS.maxIntervalsPerSection) {
    alert(`Maksymalnie ${LIMITS.maxIntervalsPerSection} interwałów w sekcji.`);
    return;
  }
  section.intervals.push({ seconds: 10 });
  displayTraining();
  recalculateIdleTime();
}

function removeInterval(sectionIndex, intervalIndex) {
  const section = training[sectionIndex];
  if (!section || section.intervals.length <= 1) return;
  section.intervals.splice(intervalIndex, 1);
  displayTraining();
  recalculateIdleTime();
}

function changeSectionRepeats(sectionIndex, value) {
  const section = training[sectionIndex];
  if (!section) return;
  section.repeats = clampInteger(value, 1, LIMITS.maxSectionRepeats, 1);
  recalculateIdleTime();
}

function addSection() {
  if (training.length >= LIMITS.maxSections) {
    alert(`Maksymalnie ${LIMITS.maxSections} sekcji.`);
    return;
  }
  training.push({ command: "", repeats: 1, intervals: [{ seconds: 10 }] });
  displayTraining();
  recalculateIdleTime();
}

function removeSection(sectionIndex) {
  if (training.length <= 1) return;
  training.splice(sectionIndex, 1);
  displayTraining();
  recalculateIdleTime();
}

function getTrainingRepeats() {
  const value = clampInteger(
    els.trainingRepeats.value, 1, LIMITS.maxTrainingRepeats, 1
  );
  els.trainingRepeats.value = String(value);
  return value;
}

function calculateTotalTrainingTime() {
  let oneTraining = 0;

  for (const section of training) {
    let sectionTime = 0;
    for (const interval of section.intervals) {
      sectionTime += interval.seconds;
    }
    oneTraining += sectionTime * section.repeats;
  }

  totalTrainingSeconds = oneTraining * getTrainingRepeats();
  return totalTrainingSeconds;
}

function recalculateIdleTime() {
  calculateTotalTrainingTime();
  if (!running) {
    remainingTrainingSeconds = totalTrainingSeconds;
    updateRemainingTime();
  }
}

function formatTime(seconds) {
  const safe = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const secs = safe % 60;

  if (hours > 0) {
    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }

  return `${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
}

function updateRemainingTime() {
  els.remainingTime.textContent = formatTime(remainingTrainingSeconds);
}

function startTraining() {
  prepareAudio();

  if (paused) {
    resumeTimer();
    return;
  }

  if (running) return;

  if (currentSection >= training.length || remainingTrainingSeconds <= 0) {
    resetPosition();
  }

  if (remainingTrainingSeconds <= 0) {
    remainingTrainingSeconds = calculateTotalTrainingTime();
  }

  running = true;
  paused = false;
  playCurrentInterval();
}

function playCurrentInterval() {
  clearTimerHandles();

  const section = training[currentSection];
  const interval = section?.intervals?.[currentInterval];

  if (!section) {
    finishTraining();
    return;
  }

  if (!interval) {
    goToNextSection();
    return;
  }

  maybeSpeakSectionCommand();

  const seconds = pausedSecondsLeft ?? interval.seconds;
  pausedSecondsLeft = null;
  currentTime = seconds;
  lastDisplayedSecond = seconds;
  intervalDeadlineMs = performance.now() + seconds * 1000;

  els.timer.textContent = String(currentTime);
  updateStatus();

  timerId = window.setInterval(timerTick, 100);
  timerTick();
}

function timerTick() {
  if (!running || paused) return;

  const msLeft = intervalDeadlineMs - performance.now();
  const secondsLeft = Math.max(0, Math.ceil(msLeft / 1000));

  if (secondsLeft !== lastDisplayedSecond) {
    const previous = lastDisplayedSecond;
    lastDisplayedSecond = secondsLeft;
    currentTime = secondsLeft;
    els.timer.textContent = String(secondsLeft);

    if (secondsLeft === 3 || secondsLeft === 2 || secondsLeft === 1) {
      warningBeep();
    }

    if (typeof previous === "number" && previous > secondsLeft) {
      remainingTrainingSeconds = Math.max(
        0,
        remainingTrainingSeconds - (previous - secondsLeft)
      );
      updateRemainingTime();
    }
  }

  if (msLeft <= 0) {
    window.clearInterval(timerId);
    timerId = null;
    currentTime = 0;
    els.timer.textContent = "0";
    finalBeep();

    transitionTimeoutId = window.setTimeout(() => {
      transitionTimeoutId = null;
      goToNextInterval();
    }, 1000);
  }
}

function maybeSpeakSectionCommand() {
  const section = training[currentSection];
  if (!section) return;

  const shouldAnnounce =
    currentSectionRepeat === 1 &&
    currentInterval === 0 &&
    section.command;

  const key = `${currentTrainingRepeat}:${currentSection}`;

  if (shouldAnnounce && announcedSectionKey !== key) {
    announcedSectionKey = key;
    speak(section.command);
  }
}

function speak(text) {
  if (!("speechSynthesis" in window)) return;

  const safeText = cleanText(text, LIMITS.maxCommandLength);
  if (!safeText) return;

  window.speechSynthesis.cancel();

  const utterance = new SpeechSynthesisUtterance(safeText);
  utterance.lang = "pl-PL";
  utterance.rate = 1;
  utterance.pitch = 1;
  utterance.volume = 1;

  window.speechSynthesis.speak(utterance);
}

function goToNextInterval() {
  currentInterval++;

  const section = training[currentSection];
  if (section && currentInterval < section.intervals.length) {
    playCurrentInterval();
    return;
  }

  goToNextSection();
}

function goToNextSection() {
  currentInterval = 0;
  currentSectionRepeat++;

  const section = training[currentSection];
  if (section && currentSectionRepeat <= section.repeats) {
    playCurrentInterval();
    return;
  }

  currentSection++;
  currentSectionRepeat = 1;

  if (currentSection < training.length) {
    playCurrentInterval();
    return;
  }

  currentTrainingRepeat++;

  if (currentTrainingRepeat <= getTrainingRepeats()) {
    currentSection = 0;
    currentInterval = 0;
    currentSectionRepeat = 1;
    playCurrentInterval();
    return;
  }

  finishTraining();
}

function updateStatus() {
  els.status.textContent =
    `Sekcja ${currentSection + 1} • Interwał ${currentInterval + 1}`;
}

function pauseTimer() {
  if (!running || paused) return;

  paused = true;

  if (timerId !== null) {
    const msLeft = Math.max(0, intervalDeadlineMs - performance.now());
    pausedSecondsLeft = Math.max(1, Math.ceil(msLeft / 1000));
  }

  clearTimerHandles();
  els.status.textContent = "Pauza";

  if ("speechSynthesis" in window) {
    window.speechSynthesis.cancel();
  }
}

function resumeTimer() {
  if (!paused) return;

  paused = false;
  running = true;

  if (pausedSecondsLeft === null) {
    goToNextInterval();
    return;
  }

  playCurrentInterval();
}

function stopTimer() {
  clearTimerHandles();

  if ("speechSynthesis" in window) {
    window.speechSynthesis.cancel();
  }

  running = false;
  paused = false;
  pausedSecondsLeft = null;
  announcedSectionKey = null;

  resetPosition();

  calculateTotalTrainingTime();
  remainingTrainingSeconds = totalTrainingSeconds;

  els.timer.textContent = "--";
  els.status.textContent = "Gotowy";
  updateRemainingTime();
}

function resetPosition() {
  currentSection = 0;
  currentInterval = 0;
  currentSectionRepeat = 1;
  currentTrainingRepeat = 1;
  currentTime = 0;
  announcedSectionKey = null;
}

function finishTraining() {
  clearTimerHandles();
  running = false;
  paused = false;
  pausedSecondsLeft = null;

  els.timer.textContent = "DONE";
  els.remainingTime.textContent = "00:00";
  els.status.textContent = "Trening zakończony";

  remainingTrainingSeconds = 0;
  currentSection = training.length;
}

function clearTimerHandles() {
  if (timerId !== null) {
    window.clearInterval(timerId);
    timerId = null;
  }
  if (transitionTimeoutId !== null) {
    window.clearTimeout(transitionTimeoutId);
    transitionTimeoutId = null;
  }
}

function prepareAudio() {
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) return;

  if (!audioContext) {
    audioContext = new AudioCtx();
  }

  if (audioContext.state === "suspended") {
    audioContext.resume().catch(() => {});
  }
}

function makeBeep(duration, gainValue) {
  prepareAudio();
  if (!audioContext) return;

  const oscillator = audioContext.createOscillator();
  const gain = audioContext.createGain();
  const now = audioContext.currentTime;

  oscillator.type = "sine";
  oscillator.frequency.value = 800;

  gain.gain.setValueAtTime(gainValue, now);
  gain.gain.setValueAtTime(gainValue, now + Math.max(0, duration - 0.15));
  gain.gain.exponentialRampToValueAtTime(0.001, now + duration);

  oscillator.connect(gain);
  gain.connect(audioContext.destination);
  oscillator.start(now);
  oscillator.stop(now + duration);
}

function warningBeep() {
  makeBeep(0.12, 0.18);
}

function finalBeep() {
  makeBeep(1.0, 0.22);
}

function loadSavedWorkouts() {
  let parsed;

  try {
    parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
  } catch {
    console.warn("Saved workouts JSON was invalid and has been ignored.");
    return [];
  }

  if (!Array.isArray(parsed)) return [];

  const safe = [];
  for (const item of parsed.slice(0, LIMITS.maxSavedWorkouts)) {
    const workout = normalizeWorkout(item);
    if (workout) safe.push(workout);
  }

  return safe;
}

function persistSavedWorkouts(workouts) {
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(workouts.slice(0, LIMITS.maxSavedWorkouts))
    );
    return true;
  } catch (error) {
    console.error("Could not save workouts:", error);
    alert("Nie udało się zapisać treningu w pamięci przeglądarki.");
    return false;
  }
}

function normalizeWorkout(raw) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.training)) {
    return null;
  }

  const safeTraining = normalizeTraining(raw.training);
  if (!safeTraining) return null;

  return {
    name: cleanText(raw.name || "Mój trening", LIMITS.maxNameLength) || "Mój trening",
    training: safeTraining,
    trainingRepeats: clampInteger(
      raw.trainingRepeats,
      1,
      LIMITS.maxTrainingRepeats,
      1
    )
  };
}

function normalizeTraining(rawTraining) {
  if (!Array.isArray(rawTraining) || rawTraining.length < 1) return null;

  const safeSections = [];

  for (const rawSection of rawTraining.slice(0, LIMITS.maxSections)) {
    if (!rawSection || typeof rawSection !== "object") continue;

    const rawIntervals = Array.isArray(rawSection.intervals)
      ? rawSection.intervals.slice(0, LIMITS.maxIntervalsPerSection)
      : [];

    const intervals = rawIntervals
      .filter(item => item && typeof item === "object")
      .map(item => ({
        seconds: clampInteger(
          item.seconds,
          1,
          LIMITS.maxIntervalSeconds,
          10
        )
      }));

    if (intervals.length === 0) continue;

    safeSections.push({
      command: cleanText(rawSection.command, LIMITS.maxCommandLength),
      repeats: clampInteger(
        rawSection.repeats,
        1,
        LIMITS.maxSectionRepeats,
        1
      ),
      intervals
    });
  }

  return safeSections.length ? safeSections : null;
}

function saveWorkout() {
  let name = cleanText(els.trainingName.value, LIMITS.maxNameLength);
  if (!name) name = "Mój trening";

  const workout = normalizeWorkout({
    name,
    training,
    trainingRepeats: getTrainingRepeats()
  });

  if (!workout) {
    alert("Nie można zapisać nieprawidłowego treningu.");
    return;
  }

  const saved = loadSavedWorkouts();

  if (saved.length >= LIMITS.maxSavedWorkouts) {
    alert(`Możesz zapisać maksymalnie ${LIMITS.maxSavedWorkouts} treningów.`);
    return;
  }

  saved.push(workout);

  if (!persistSavedWorkouts(saved)) return;

  els.trainingName.value = workout.name;
  displaySavedWorkouts();
  alert(`Trening "${workout.name}" został zapisany.`);
}

function displaySavedWorkouts() {
  const saved = loadSavedWorkouts();
  els.savedWorkouts.replaceChildren();

  if (saved.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "Nie masz jeszcze zapisanych treningów.";
    els.savedWorkouts.appendChild(empty);
    return;
  }

  saved.forEach((workout, index) => {
    const row = document.createElement("div");
    row.className = "saved-workout";

    const name = document.createElement("div");
    name.className = "saved-workout-name";

    // Critical XSS protection: textContent treats the stored name as text,
    // even if it contains strings such as <script> or event-handler syntax.
    name.textContent = workout.name;

    const buttons = document.createElement("div");
    buttons.className = "saved-workout-buttons";

    const load = makeButton(
      "▶ WCZYTAJ",
      "load-button",
      () => loadWorkout(index)
    );

    const remove = makeButton(
      "🗑",
      "delete-saved-button",
      () => deleteWorkout(index),
      `Usuń zapisany trening ${workout.name}`
    );

    buttons.append(load, remove);
    row.append(name, buttons);
    els.savedWorkouts.appendChild(row);
  });
}

function loadWorkout(index) {
  const saved = loadSavedWorkouts();
  const workout = saved[index];
  if (!workout) return;

  stopTimer();

  training = structuredCloneSafe(workout.training);
  els.trainingName.value = workout.name;
  els.trainingRepeats.value = String(workout.trainingRepeats);

  displayTraining();
  calculateTotalTrainingTime();
  remainingTrainingSeconds = totalTrainingSeconds;
  updateRemainingTime();

  els.status.textContent = "Trening wczytany";
}

function deleteWorkout(index) {
  const saved = loadSavedWorkouts();
  const workout = saved[index];
  if (!workout) return;

  if (!confirm(`Usunąć trening "${workout.name}"?`)) return;

  saved.splice(index, 1);
  if (persistSavedWorkouts(saved)) {
    displaySavedWorkouts();
  }
}
