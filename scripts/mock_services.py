#!/usr/bin/env python3
"""Local stand-in for the AssemblyAI and Groq endpoints the app uses.

Development tooling only, for exercising a Debug build end to end without API keys or cost:

    scripts/mock_services.py <fixtures>/transcripts.json [port]

    MICINGEST_PROFILE=e2e \\
    MICINGEST_ASSEMBLYAI_URL=http://127.0.0.1:8765 \\
    MICINGEST_GROQ_URL=http://127.0.0.1:8765/openai/v1 \\
    MICINGEST_SOURCE=<fixtures>/DJI MICINGEST_DESTINATION=<some folder> \\
    <build>/MicIngest.app/Contents/MacOS/MicIngest

AssemblyAI: an upload is matched to a scripted transcript by its audio duration, and the job
completes after two polls. Groq: answers the structured speaker-name request by looking for
plain self-introductions ("ich bin X", "mein Name ist X") in the transcript text it was sent.
Every request is logged to stdout (without credentials) so the wire format can be inspected.
"""
import json
import re
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

transcripts = []
uploads = {}   # upload URL -> scripted transcript
jobs = {}      # transcript id -> {"polls": n, "transcript": {...}}

INTRODUCTION = re.compile(r"\b(?:ich bin|ich heiße|mein name ist|my name is)\s+([A-ZÄÖÜ][a-zäöüß]+)\b", re.IGNORECASE)
LINE = re.compile(r"^\[(u\d+)\] Speaker (\w+): (.*)$", re.MULTILINE)
NOT_NAMES = {"gerade", "jetzt", "heute", "gegen", "schon", "noch", "froh", "sicher", "dabei", "auch", "nicht"}


def duration_of(data):
    with tempfile.NamedTemporaryFile(suffix=".audio") as f:
        f.write(data)
        f.flush()
        info = subprocess.run(["afinfo", f.name], capture_output=True, text=True).stdout
    match = re.search(r"estimated duration: ([0-9.]+)", info)
    return float(match.group(1)) if match else None, re.search(r"Data format:\s+(.*)", info)


def name_findings(prompt):
    speakers = {}
    for utterance_id, speaker, text in LINE.findall(prompt):
        entry = speakers.setdefault(speaker, {"speaker": speaker, "suggestedName": None, "confidence": "low",
                                              "basis": "none", "evidence": []})
        match = INTRODUCTION.search(text)
        if match and match.group(1).lower() not in NOT_NAMES and entry["suggestedName"] is None:
            entry.update(suggestedName=match.group(1), confidence="high", basis="self_identification",
                         evidence=[{"utteranceId": utterance_id, "quote": match.group(0),
                                    "reason": f"The speaker introduces themselves as {match.group(1)}."}])
    return {"speakers": list(speakers.values())}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def reply(self, payload, status=200):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization"):
            return True
        self.reply({"error": "Authentication error, API token missing/invalid"}, 401)
        return False

    def do_GET(self):
        if not self.authorized():
            return
        path = self.path.split("?")[0]
        print(f"GET  {self.path}", flush=True)
        if path == "/v2/transcript":
            return self.reply({"transcripts": []})
        if path == "/openai/v1/models":
            return self.reply({"object": "list", "data": [{"id": "openai/gpt-oss-120b"}]})
        job = jobs.get(path.rsplit("/", 1)[-1])
        if not path.startswith("/v2/transcript/") or job is None:
            return self.reply({"error": "Transcript lookup error, transcript id not found"}, 404)
        job["polls"] += 1
        if job["polls"] <= 2:
            return self.reply({"id": job["id"], "status": "processing"})
        script = job["transcript"]
        utterances = script["utterances"]
        self.reply({
            "id": job["id"], "status": "completed", "language_code": "de", "speech_model_used": job["model"],
            "audio_duration": round(script["durationSeconds"]), "confidence": 0.94,
            "text": " ".join(u["text"] for u in utterances),
            "utterances": utterances or None,
            "words": [],
        })

    def do_POST(self):
        data = self.body()
        if not self.authorized():
            return
        if self.path == "/v2/upload":
            seconds, fmt = duration_of(data)
            print(f"POST /v2/upload  {len(data)} bytes, {seconds} s, {fmt.group(1) if fmt else '?'}", flush=True)
            if seconds is None:
                return self.reply({"error": "Upload failed: not an audio file"}, 422)
            match = min(transcripts, key=lambda t: abs(t["durationSeconds"] - seconds))
            if abs(match["durationSeconds"] - seconds) > 1:
                match = {"durationSeconds": seconds, "utterances": []}
            url = f"http://127.0.0.1/upload/{len(uploads) + 1}"
            uploads[url] = match
            return self.reply({"upload_url": url})
        if self.path == "/v2/transcript":
            request = json.loads(data)
            print(f"POST /v2/transcript  {json.dumps(request, ensure_ascii=False)}", flush=True)
            if request.get("audio_url") not in uploads:
                return self.reply({"error": "Cannot access uploaded file"}, 403)
            job_id = f"mock-{len(jobs) + 1:04d}"
            jobs[job_id] = {"id": job_id, "polls": 0, "transcript": uploads[request["audio_url"]],
                            "model": request.get("speech_models", ["universal-3-5-pro"])[0]}
            return self.reply({"id": job_id, "status": "queued"})
        if self.path == "/openai/v1/chat/completions":
            request = json.loads(data)
            prompt = request["messages"][-1]["content"]
            findings = name_findings(prompt)
            named = {s["speaker"]: s["suggestedName"] for s in findings["speakers"] if s["suggestedName"]}
            print(f"POST /chat/completions  model={request.get('model')} "
                  f"format={request.get('response_format', {}).get('type')} "
                  f"strict={request.get('response_format', {}).get('json_schema', {}).get('strict')} "
                  f"prompt={len(prompt)} chars → {named}", flush=True)
            return self.reply({"choices": [{"index": 0, "message": {
                "role": "assistant", "content": json.dumps(findings, ensure_ascii=False)}}]})
        self.reply({"error": "not found"}, 404)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        transcripts.extend(json.load(f))
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
    print(f"mock AssemblyAI + Groq on http://127.0.0.1:{port} ({len(transcripts)} scripted transcripts)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
