import { useRef, useState } from 'react'
import {
  createTransactionFromPhoto,
  createTransactionFromText,
  createTransactionFromVoice,
} from './api.js'

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

export default function QuickTransactionActions({ open, onToggle, onCompleted }) {
  const fileRef = useRef(null)
  const recorderRef = useRef(null)
  const streamRef = useRef(null)
  const chunksRef = useRef([])
  const [textOpen, setTextOpen] = useState(false)
  const [text, setText] = useState('')
  const [voiceOpen, setVoiceOpen] = useState(false)
  const [recording, setRecording] = useState(false)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState('')

  const finish = async (message = 'Операция добавлена') => {
    setStatus(message)
    await onCompleted?.()
    window.setTimeout(() => setStatus(''), 1800)
  }

  const uploadPhoto = async (event) => {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (!file || busy) return
    onToggle(false)
    setBusy(true)
    setStatus('Обрабатываю фото…')
    try {
      await createTransactionFromPhoto(file)
      await finish()
    } catch (error) {
      setStatus('')
      showError(error?.message || 'Не удалось обработать фото')
    } finally {
      setBusy(false)
    }
  }

  const submitText = async () => {
    const value = text.trim()
    if (!value || busy) return
    setBusy(true)
    setStatus('Обрабатываю текст…')
    try {
      await createTransactionFromText(value)
      setText('')
      setTextOpen(false)
      await finish()
    } catch (error) {
      setStatus('')
      showError(error?.message || 'Не удалось обработать текст')
    } finally {
      setBusy(false)
    }
  }

  const stopTracks = () => {
    streamRef.current?.getTracks?.().forEach((track) => track.stop())
    streamRef.current = null
  }

  const startRecording = async () => {
    if (busy || recording) return
    try {
      if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
        throw new Error('Запись аудио недоступна в этом браузере.')
      }
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const recorder = new MediaRecorder(stream)
      streamRef.current = stream
      chunksRef.current = []
      recorder.ondataavailable = (event) => {
        if (event.data?.size) chunksRef.current.push(event.data)
      }
      recorder.onstop = async () => {
        const blob = new Blob(chunksRef.current, { type: recorder.mimeType || 'audio/webm' })
        stopTracks()
        setRecording(false)
        setBusy(true)
        setStatus('Обрабатываю аудио…')
        try {
          await createTransactionFromVoice(blob)
          setVoiceOpen(false)
          await finish()
        } catch (error) {
          setStatus('')
          showError(error?.message || 'Не удалось обработать аудио')
        } finally {
          setBusy(false)
          recorderRef.current = null
        }
      }
      recorderRef.current = recorder
      recorder.start()
      setRecording(true)
    } catch (error) {
      stopTracks()
      setRecording(false)
      showError(error?.message || 'Не удалось включить микрофон')
    }
  }

  const stopRecording = () => {
    if (recorderRef.current?.state === 'recording') recorderRef.current.stop()
  }

  const cancelVoice = () => {
    const recorder = recorderRef.current
    if (recorder?.state === 'recording') {
      recorder.onstop = () => stopTracks()
      recorder.stop()
    } else stopTracks()
    recorderRef.current = null
    setRecording(false)
    setVoiceOpen(false)
  }

  return (
    <>
      <input ref={fileRef} className="quickTransactionFile" type="file" accept="image/*" onChange={uploadPhoto} />
      <div className={`fabMenu ${open ? 'open' : ''}`}>
        <div className="fabActions" aria-hidden={!open}>
          <button type="button" className="fabAction" disabled={busy} onClick={() => fileRef.current?.click()}><span>Фото</span><b aria-hidden="true">▣</b></button>
          <button type="button" className="fabAction" disabled={busy} onClick={() => { onToggle(false); setTextOpen(true) }}><span>Текст</span><b aria-hidden="true">✎</b></button>
          <button type="button" className="fabAction" disabled={busy} onClick={() => { onToggle(false); setVoiceOpen(true) }}><span>Аудио</span><b aria-hidden="true">●</b></button>
        </div>
        <button type="button" className="fab" disabled={busy} onClick={() => onToggle(!open)} aria-label={open ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'} aria-expanded={open}><span aria-hidden="true">{open ? '×' : '+'}</span></button>
      </div>

      {status && <div className="quickTransactionStatus" role="status">{status}</div>}

      {textOpen && (
        <div className="quickTransactionBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && setTextOpen(false)}>
          <section className="quickTransactionSheet" role="dialog" aria-modal="true" aria-label="Добавить операцию текстом">
            <header><strong>Добавить текстом</strong><button type="button" onClick={() => setTextOpen(false)}>×</button></header>
            <textarea value={text} onChange={(event) => setText(event.target.value)} placeholder="Например: кофе 4.50 EUR с Cash EUR" autoFocus />
            <button type="button" className="quickTransactionPrimary" disabled={busy || !text.trim()} onClick={submitText}>{busy ? 'Обработка…' : 'Добавить'}</button>
          </section>
        </div>
      )}

      {voiceOpen && (
        <div className="quickTransactionBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && !recording && setVoiceOpen(false)}>
          <section className="quickTransactionSheet voice" role="dialog" aria-modal="true" aria-label="Добавить операцию аудио">
            <header><strong>Добавить аудио</strong><button type="button" onClick={cancelVoice}>×</button></header>
            <p>{recording ? 'Запись идёт…' : 'Нажмите «Записать» и продиктуйте операцию.'}</p>
            {!recording
              ? <button type="button" className="quickTransactionPrimary" disabled={busy} onClick={startRecording}>Записать</button>
              : <button type="button" className="quickTransactionPrimary recording" onClick={stopRecording}>Остановить и отправить</button>}
          </section>
        </div>
      )}
    </>
  )
}