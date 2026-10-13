#!/usr/bin/env python3
"""Builds a folder that looks like a DJI Mic after an evening of recording.

Development tooling only (the app itself has no Python dependency). Uses the macOS `say`
command for speech, so the audio is real speech from several distinct voices, and writes
48 kHz / 24-bit mono WAV chunks with the recorder's file naming and 30-minute rollover.

    scripts/make_fixtures.py <output-folder>

Writes the recorder files into <output-folder>/DJI and the matching diarized transcripts
(what a speech-to-text service would return) into <output-folder>/transcripts.json for
scripts/mock_services.py. About 1.7 GB.
"""
import json
import os
import random
import subprocess
import sys
import tempfile
import wave

RATE = 48_000
WIDTH = 3  # bytes per sample: 24-bit

# Voices that the embedding model tells apart clearly (Eddy and Reed, for example, it does not).
VOICES = {
    "alex": "Reed (German (Germany))",
    "sam": "Rocko (German (Germany))",
    "guest": "Anna",
    "robert": "Sandy (German (Germany))",
}

# (filename, duration in seconds). Timestamps follow the product brief.
FILES = [
    ("TX01_MIC001_20261001_193402_orig.wav", 754.0),
    ("TX01_MIC002_20261001_204349_orig.wav", 1800.5),
    ("TX01_MIC003_20261001_211350_orig.wav", 1800.0),
    ("TX01_MIC004_20261001_214350_orig.wav", 1800.0),
    ("TX01_MIC005_20261001_221350_orig.wav", 1800.0),
    ("TX01_MIC006_20261001_224350_orig.wav", 497.0),
    ("TX01_MIC007_20261001_232928_orig.wav", 9.4),
    ("TX01_MIC008_20261001_232938_orig.wav", 1.8),
    ("TX01_MIC009_20261001_232940_orig.wav", 3.0),
    ("TX01_MIC010_20261001_233414_orig.wav", 1800.0),
    ("TX01_MIC011_20261002_000414_orig.wav", 1433.0),
]

# Sessions as the app should group them: (file indices, [(earliest offset in session, voice, text)]).
SESSIONS = [
    ([0], [
        (5, "alex", "So, die Aufnahme läuft jetzt. Ich wollte kurz mit dir über die Fahrt am Wochenende sprechen, bevor wir das wieder vergessen."),
        (0, "sam", "Hi, ich bin Sam. Ich bin gerade erst angekommen und habe noch nicht einmal meine Jacke ausgezogen."),
        (0, "alex", "Kein Problem, setz dich erst mal. Ich glaube, wir sollten am Samstag deutlich früher losfahren als beim letzten Mal."),
        (0, "sam", "Ja, das denke ich auch. Beim letzten Mal standen wir fast zwei Stunden im Stau, das möchte ich wirklich nicht noch einmal erleben."),
        (0, "alex", "Genau. Dann treffen wir uns um sieben Uhr bei mir und nehmen mein Auto, weil da mehr Gepäck hineinpasst."),
        (0, "sam", "Einverstanden. Ich bringe Kaffee und etwas zu essen mit, damit wir unterwegs nicht anhalten müssen. By the way, did you book the hotel already?"),
        (0, "alex", "Yes, I booked it yesterday. Zwei Nächte, direkt am See, mit Frühstück und einem Parkplatz vor der Tür."),
        (600, "sam", "Okay, dann sehen wir uns am Samstag. Ich schreibe dir noch, wann ich genau losfahre und was ich alles mitbringe."),
    ]),
    ([1, 2, 3, 4, 5], [
        (14, "alex", "Ich glaube, wir sollten morgen früher losfahren, damit wir vor dem ganzen Verkehr aus der Stadt herauskommen."),
        (0, "sam", "Ja, denke ich auch. Ich habe mir die Strecke vorhin noch einmal angesehen und es gibt zwei größere Baustellen."),
        (0, "guest", "Alex hat mir gestern erzählt, dass ihr über die Landstraße fahren wollt. Das dauert zwar länger, ist aber deutlich entspannter."),
        (0, "alex", "Das stimmt, über die Landstraße brauchen wir ungefähr zwanzig Minuten länger, aber dafür stehen wir nicht im Stau."),
        (0, "sam", "Mir ist das recht. Hauptsache, wir kommen entspannt an und haben am Abend noch Zeit, etwas essen zu gehen."),
        (0, "guest", "Dann nehme ich lieber den Zug und wir treffen uns direkt am Hotel. Ich muss am Vormittag sowieso noch arbeiten."),
        (0, "alex", "Alles klar. Schick uns einfach eine Nachricht, sobald du am Bahnhof angekommen bist, dann holen wir dich ab."),
        (0, "guest", "Mache ich. Ich denke, ich bin gegen fünf Uhr da, vielleicht auch etwas früher, wenn der Anschluss klappt."),
        (3600, "alex", "Okay, weiter geht's. Wir sind jetzt seit einer Stunde unterwegs und liegen wirklich gut in der Zeit."),
        (0, "sam", "Sehr gut. Dann können wir in einer halben Stunde eine kurze Pause machen und etwas trinken."),
        (7600, "guest", "Ich glaube, wir sind gleich da. Da vorne ist schon die Ausfahrt, die wir nehmen müssen."),
    ]),
    ([6], [(1, "alex", "Test, eins, zwei, drei.")]),
    ([7], []),
    ([8], []),
    ([9, 10], [
        (20, "robert", "Guten Abend zusammen. Mein Name ist Robert und ich bin heute zum ersten Mal dabei, also seid bitte nachsichtig mit mir."),
        (0, "sam", "Herzlich willkommen. Wir fangen gleich an, sobald alle da sind und jeder etwas zu trinken hat."),
        (0, "robert", "Vielen Dank. Ich habe die Unterlagen schon gelesen und mir ein paar Fragen dazu aufgeschrieben."),
        (0, "sam", "Sehr gut, dann gehen wir die Fragen gleich der Reihe nach durch und halten die Antworten fest."),
        (0, "robert", "Die erste Frage betrifft den Zeitplan. Ich finde, drei Wochen sind dafür ziemlich knapp bemessen."),
        (1795, "sam", "Es ist jetzt kurz nach Mitternacht. Ich schlage vor, wir machen noch zehn Minuten weiter und hören dann auf."),
        (0, "robert", "Einverstanden. Den Rest können wir auch morgen in Ruhe per Telefon besprechen."),
    ]),
]


def noise_second(seed):
    """One second of very quiet room noise (around -66 dBFS) as 24-bit little-endian bytes."""
    rng = random.Random(seed)
    out = bytearray()
    for _ in range(RATE):
        out += int(rng.gauss(0, 4200)).to_bytes(4, "little", signed=True)[:WIDTH]
    return bytes(out)


def speak(voice, text, folder, cache={}):
    """Synthesizes `text`; returns raw 24-bit / 48 kHz mono sample bytes."""
    key = (voice, text)
    if key not in cache:
        path = os.path.join(folder, f"say{len(cache)}.wav")
        subprocess.run(["say", "-v", VOICES[voice], "-o", path, "--file-format=WAVE",
                        f"--data-format=LEI24@{RATE}", text], check=True)
        with wave.open(path) as w:
            assert (w.getframerate(), w.getsampwidth(), w.getnchannels()) == (RATE, WIDTH, 1)
            cache[key] = w.readframes(w.getnframes())
    return cache[key]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    recorder = os.path.join(out, "DJI")
    os.makedirs(recorder, exist_ok=True)
    noise = noise_second(7)
    transcripts = []

    with tempfile.TemporaryDirectory() as tmp:
        for indices, script in SESSIONS:
            total = sum(FILES[i][1] for i in indices)
            frames = sum(round(FILES[i][1] * RATE) for i in indices)
            audio = bytearray((noise * (frames // RATE + 1))[: frames * WIDTH])

            utterances, labels, cursor = [], {}, 0.0
            for earliest, voice, text in script:
                speech = speak(voice, text, tmp)
                start = max(earliest, cursor + 0.7)
                first = round(start * RATE) * WIDTH
                assert first + len(speech) <= len(audio), "script does not fit into the session"
                audio[first:first + len(speech)] = speech
                end = start + len(speech) / WIDTH / RATE
                cursor = end
                label = labels.setdefault(voice, chr(ord("A") + len(labels)))
                utterances.append({"speaker": label, "start": round(start * 1000), "end": round(end * 1000),
                                   "text": text, "confidence": 0.94, "words": []})
            transcripts.append({"durationSeconds": total, "files": [FILES[i][0] for i in indices], "utterances": utterances})

            position = 0
            for i in indices:
                name, seconds = FILES[i]
                size = round(seconds * RATE) * WIDTH
                with wave.open(os.path.join(recorder, name), "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(WIDTH)
                    w.setframerate(RATE)
                    w.writeframes(bytes(audio[position:position + size]))
                position += size
                print(f"wrote {name}  {seconds:8.1f} s")

    with open(os.path.join(out, "transcripts.json"), "w") as f:
        json.dump(transcripts, f, ensure_ascii=False, indent=1)
    print(f"{len(FILES)} files in {recorder}")


if __name__ == "__main__":
    main()
