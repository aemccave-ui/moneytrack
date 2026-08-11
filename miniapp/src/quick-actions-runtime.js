import {
  createTransactionFromPhoto,
  createTransactionFromText,
  createTransactionFromVoice,
} from './api.js'

let busy = false
let recorder = null
let stream = null
let chunks = []

function telegramAlert(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function status(message = '') {
  document.querySelector('.quickTransactionStatusRuntime')?.remove()
  if (!message) return
  const node = document.createElement('div')
  node.className = 'quickTransactionStatus quickTransactionStatusRuntime'
  node.setAttribute('role', 'status')
  node.textContent = message
  document.body.appendChild(node)
}

async function completed() {
  status('Операция добавлена')
  window.setTimeout(() => window.location.reload(), 450)
}

async function run(task, pendingLabel) {
  if (busy) return
  busy = true
  status(pendingLabel)
  try {
    await task()
    await completed()
  } catch (error) {
    status('')
    telegramAlert(error?.message || 'Не удалось добавить операцию')
  } finally {
    busy = false
  }
}

const photoInput = document.createElement('input')
photoInput.type = 'file'
photoInput.accept = 'image/*'
photoInput.className = 'quickTransactionFile'
photoInput.addEventListener('change', () => {
  const file = photoInput.files?.[0]
  photoInput.value = ''
  if (!file) return
  void run(() => createTransactionFromPhoto(file), 'Обрабатываю фото…')
})
document.body.appendChild(photoInput)

function closeModal() {
  document.querySelector('.quickTransactionBackdrop.runtime')?.remove()
}

function openText() {
  closeModal()
  const backdrop = document.createElement('div')
  backdrop.className = 'quickTransactionBackdrop runtime'
  backdrop.innerHTML = `
    <section class="quickTransactionSheet" role="dialog" aria-modal="true" aria-label="Добавить операцию текстом">
      <header><strong>Добавить текстом</strong><button type="button" data-close>×</button></header>
      <textarea data-text placeholder="Например: кофе 4.50 EUR с Cash EUR"></textarea>
      <button type="button" class="quickTransactionPrimary" data-submit>Добавить</button>
    </section>`
  backdrop.addEventListener('click', (event) => {
    if (event.target === backdrop || event.target.closest('[data-close]')) closeModal()
    if (event.target.closest('[data-submit]')) {
      const text = backdrop.querySelector('[data-text]')?.value?.trim()
      if (!text) return
      closeModal()
      void run(() => createTransactionFromText(text), 'Обрабатываю текст…')
    }
  })
  document.body.appendChild(backdrop)
  window.setTimeout(() => backdrop.querySelector('[data-text]')?.focus(), 0)
}

function stopTracks() {
  stream?.getTracks?.().forEach((track) => track.stop())
  stream = null
}

function openAudio() {
  closeModal()
  const backdrop = document.createElement('div')
  backdrop.className = 'quickTransactionBackdrop runtime'
  backdrop.innerHTML = `
    <section class="quickTransactionSheet voice" role="dialog" aria-modal="true" aria-label="Добавить операцию аудио">
      <header><strong>Добавить аудио</strong><button type="button" data-close>×</button></header>
      <p data-state>Нажмите «Записать» и продиктуйте операцию.</p>
      <button type="button" class="quickTransactionPrimary" data-record>Записать</button>
    </section>`

  const cancel = () => {
    if (recorder?.state === 'recording') {
      recorder.onstop = () => stopTracks()
      recorder.stop()
    } else stopTracks()
    recorder = null
    chunks = []
    closeModal()
  }

  backdrop.addEventListener('click', async (event) => {
    if (event.target === backdrop || event.target.closest('[data-close]')) {
      cancel()
      return
    }
    const button = event.target.closest('[data-record]')
    if (!button || busy) return
    if (recorder?.state === 'recording') {
      recorder.stop()
      return
    }
    try {
      if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
        throw new Error('Запись аудио недоступна в этом браузере.')
      }
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      chunks = []
      recorder = new MediaRecorder(stream)
      recorder.ondataavailable = (dataEvent) => {
        if (dataEvent.data?.size) chunks.push(dataEvent.data)
      }
      recorder.onstop = () => {
        const blob = new Blob(chunks, { type: recorder.mimeType || 'audio/webm' })
        stopTracks()
        recorder = null
        closeModal()
        void run(() => createTransactionFromVoice(blob), 'Обрабатываю аудио…')
      }
      recorder.start()
      backdrop.querySelector('[data-state]').textContent = 'Запись идёт…'
      button.textContent = 'Остановить и отправить'
      button.classList.add('recording')
    } catch (error) {
      stopTracks()
      recorder = null
      telegramAlert(error?.message || 'Не удалось включить микрофон')
    }
  })

  document.body.appendChild(backdrop)
}

function normalizeHomeActions() {
  document.querySelectorAll('.fabAction').forEach((button) => {
    const labelNode = button.querySelector('span')
    if (labelNode?.textContent?.trim() === 'Голос') labelNode.textContent = 'Аудио'
  })
}

function closeHomeFab(button) {
  const menu = button.closest('.fabMenu')
  const toggle = menu?.querySelector('.fab')
  if (menu?.classList.contains('open') && toggle) window.setTimeout(() => toggle.click(), 0)
}

const observer = new MutationObserver(normalizeHomeActions)
observer.observe(document.body, { childList: true, subtree: true })
normalizeHomeActions()

document.addEventListener('click', (event) => {
  const button = event.target.closest('.fabAction')
  if (!button || button.closest('.accountSheet')) return
  const label = button.querySelector('span')?.textContent?.trim()
  if (!['Фото', 'Текст', 'Аудио', 'Голос'].includes(label)) return
  event.preventDefault()
  event.stopPropagation()
  closeHomeFab(button)
  if (label === 'Фото') photoInput.click()
  else if (label === 'Текст') openText()
  else openAudio()
}, true)
