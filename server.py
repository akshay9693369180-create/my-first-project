"""
NCC AI Learning Portal - Backend Flask Server & PDF Engine API
Serves static portal assets and provides endpoints for PDF reading, full-document optimization,
Q&A retrieval, and downloadable exam study sheets.
"""

import os
import io
import sys
import json
import base64

# Ensure UTF-8 console output on Windows
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from flask import Flask, request, jsonify, send_from_directory, Response
from pdf_engine import NccPdfOptimizerEngine
from ai_assistant_engine import NccAiAssistantEngine

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, static_folder=BASE_DIR, static_url_path="")
engine = NccPdfOptimizerEngine()
ai_assistant = NccAiAssistantEngine()

# Initialize sample document into cache
SAMPLE_PDF_PATH = os.path.join(BASE_DIR, "sample_ncc_paper.pdf")
SAMPLE_DOC_ID = "doc_sample_ncc_2009"

def init_sample_doc():
    if os.path.exists(SAMPLE_PDF_PATH):
        try:
            with open(SAMPLE_PDF_PATH, "rb") as f:
                data = engine.extract_text_from_bytes(f.read())
            result = engine.optimize_entire_document(data["full_text"], "NCC_Question_Paper_2009.pdf")
            result["doc_id"] = SAMPLE_DOC_ID
            result["num_pages"] = data["num_pages"]
            engine.doc_store[SAMPLE_DOC_ID] = result
            print(f"[Backend] Pre-cached sample document: {SAMPLE_DOC_ID} ({data['num_pages']} pages)")
        except Exception as e:
            print(f"[Backend] Warning: could not pre-cache sample PDF: {e}")

init_sample_doc()

# =======================================================
# CORS & STATIC FILE ROUTING
# =======================================================

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type,Authorization"
    response.headers["Access-Control-Allow-Methods"] = "GET,PUT,POST,DELETE,OPTIONS"
    return response

@app.route("/")
def index():
    return send_from_directory(BASE_DIR, "index.html")


# =======================================================
# API ENDPOINTS FOR PDF READER & OPTIMIZER
# =======================================================

@app.route("/api/health", methods=["GET"])
def health_check():
    return jsonify({
        "status": "online",
        "service": "NCC AI Learning Portal - PDF Optimizer Backend",
        "cached_documents": len(engine.doc_store),
        "engine": "NccPdfOptimizerEngine (Zero-Loss Fluff Reduction & Syllabus Extraction)"
    })

@app.route("/api/pdf/sample", methods=["GET"])
def get_sample_document():
    """
    Returns pre-computed full optimization for the official NCC 2009 Question Paper.
    """
    if SAMPLE_DOC_ID in engine.doc_store:
        return jsonify({"success": True, "data": engine.doc_store[SAMPLE_DOC_ID]})
    return jsonify({"success": False, "error": "Sample document not initialized"}), 404

@app.route("/api/pdf/upload", methods=["POST"])
def upload_pdf():
    """
    Upload and parse any PDF file or base64 data.
    Extracts text, calculates metrics, structures syllabus, and generates mock quiz.
    """
    try:
        filename = "Uploaded_Document.pdf"
        file_bytes = None
        raw_text = None

        if "file" in request.files:
            uploaded_file = request.files["file"]
            filename = uploaded_file.filename or filename
            file_bytes = uploaded_file.read()
        elif request.is_json:
            data = request.get_json()
            filename = data.get("filename", filename)
            if "base64" in data:
                file_bytes = base64.b64decode(data["base64"])
            elif "text" in data:
                raw_text = data["text"]

        if file_bytes:
            extracted = engine.extract_text_from_bytes(file_bytes)
            num_pages = extracted["num_pages"]
            full_text = extracted["full_text"]
        elif raw_text:
            num_pages = max(1, len(raw_text) // 1800)
            full_text = raw_text
        else:
            return jsonify({"success": False, "error": "No file or text payload provided"}), 400

        # Execute full document optimization
        optimization = engine.optimize_entire_document(full_text, filename)
        optimization["num_pages"] = num_pages
        doc_id = optimization["doc_id"]

        # Cache document
        engine.doc_store[doc_id] = optimization

        return jsonify({
            "success": True,
            "doc_id": doc_id,
            "filename": filename,
            "num_pages": num_pages,
            "data": optimization
        })

    except Exception as e:
        return jsonify({"success": False, "error": f"Failed to parse and optimize PDF: {str(e)}"}), 500

@app.route("/api/pdf/optimize", methods=["POST"])
def optimize_pdf():
    """
    Optimizes a document by doc_id or by raw text string.
    """
    try:
        data = request.get_json() or {}
        doc_id = data.get("doc_id")
        raw_text = data.get("text")
        filename = data.get("filename", "NCC_Document.pdf")

        if doc_id and doc_id in engine.doc_store:
            return jsonify({"success": True, "data": engine.doc_store[doc_id]})

        if not raw_text and doc_id == SAMPLE_DOC_ID:
            if SAMPLE_DOC_ID in engine.doc_store:
                return jsonify({"success": True, "data": engine.doc_store[SAMPLE_DOC_ID]})

        if not raw_text:
            return jsonify({"success": False, "error": "No text or valid doc_id provided for optimization"}), 400

        optimization = engine.optimize_entire_document(raw_text, filename)
        return jsonify({"success": True, "data": optimization})

    except Exception as e:
        return jsonify({"success": False, "error": f"Optimization failed: {str(e)}"}), 500

@app.route("/api/pdf/ask", methods=["POST"])
def ask_document():
    """
    Answers user queries about an uploaded or preloaded PDF document.
    """
    try:
        data = request.get_json() or {}
        query = data.get("query", "").strip()
        doc_id = data.get("doc_id")
        text = data.get("text")
        filename = data.get("filename", "NCC Document")

        if not query:
            return jsonify({"success": False, "error": "No query specified"}), 400

        doc_text = ""
        if doc_id and doc_id in engine.doc_store:
            doc_text = engine.doc_store[doc_id].get("cleaned_text", "")
            filename = engine.doc_store[doc_id].get("document_name", filename)
        elif text:
            doc_text = text
        elif SAMPLE_DOC_ID in engine.doc_store:
            doc_text = engine.doc_store[SAMPLE_DOC_ID].get("cleaned_text", "")
            filename = "Official NCC Question Paper (2009)"

        result = engine.answer_query(query, doc_text, filename)
        return jsonify({"success": True, "result": result})

    except Exception as e:
        return jsonify({"success": False, "error": f"Search failed: {str(e)}"}), 500

@app.route("/api/pdf/download/<doc_id>", methods=["GET"])
def download_optimized_notes(doc_id):
    """
    Downloads clean, formatted Markdown revision notes for offline study.
    """
    doc = engine.doc_store.get(doc_id)
    if not doc:
        # Fallback to sample document
        doc = engine.doc_store.get(SAMPLE_DOC_ID)

    if not doc:
        return jsonify({"error": "Document not found"}), 404

    md_content = doc.get("optimized_markdown", "# NCC Optimized Revision Notes")
    filename = f"Optimized_Revision_{doc.get('document_name', 'Document')}.md"
    filename = filename.replace(".pdf.md", ".md")

    return Response(
        md_content,
        mimetype="text/markdown",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"'
        }
    )

@app.route("/api/ai/chat", methods=["POST"])
def ai_chat():
    """
    Modern conversational AI endpoint for NCC Cadets.
    Maintains multi-turn context, supports multi-language queries,
    and grounds responses in uploaded study materials or question banks.
    """
    try:
        data = request.get_json(silent=True) or {}
        message = data.get("message", "").strip()
        history = data.get("history", [])
        doc_id = data.get("doc_id")
        uploaded_text = data.get("uploaded_text", "")
        doc_name = data.get("doc_name", "")
        requested_lang = data.get("requested_lang", "auto")

        if not message:
            return jsonify({"success": False, "error": "No message provided"}), 400

        # Retrieve document text from engine cache if doc_id provided
        if doc_id and doc_id in engine.doc_store:
            uploaded_text = engine.doc_store[doc_id].get("cleaned_text", uploaded_text)
            doc_name = engine.doc_store[doc_id].get("document_name", doc_name)

        client_api_key = data.get("api_key") or request.headers.get("X-API-Key")

        response = ai_assistant.generate_response(
            prompt=message,
            history=history,
            doc_text=uploaded_text,
            doc_name=doc_name,
            requested_lang=requested_lang,
            api_key=client_api_key
        )

        return jsonify({
            "success": True,
            "data": response
        })

    except Exception as e:
        return jsonify({"success": False, "error": f"NCC AI Agent error: {str(e)}"}), 500

# =======================================================
# API KEY MANAGEMENT & VERIFICATION ENDPOINTS
# =======================================================

@app.route("/api/config/auth", methods=["GET"])
def get_auth_config():
    """
    Returns public OAuth configuration for Google Identity Services.
    """
    google_client_id = os.environ.get("GOOGLE_CLIENT_ID", "").strip()
    return jsonify({
        "success": True,
        "google_client_id": google_client_id,
        "has_google_oauth": bool(google_client_id)
    })

@app.route("/api/config/api-key", methods=["GET"])
def get_api_key_status():
    """
    Returns API key configuration status and active provider without leaking the secret.
    """
    masked = ai_assistant.get_masked_key()
    provider_info = ai_assistant.get_active_provider()
    has_key = bool(ai_assistant.openai_api_key or ai_assistant.gemini_api_key or os.environ.get("OPENAI_API_KEY") or os.environ.get("GEMINI_API_KEY"))
    return jsonify({
        "success": True,
        "configured": has_key,
        "masked_key": masked,
        "provider": provider_info["provider"],
        "model": provider_info["model"],
        "has_env_file": os.path.exists(os.path.join(BASE_DIR, ".env"))
    })

@app.route("/api/config/api-key", methods=["POST"])
def update_api_key():
    """
    Saves or clears API key dynamically into .env and memory.
    Supports both OpenAI (sk-...) and Google Gemini.
    """
    try:
        data = request.get_json(silent=True) or {}
        new_key = data.get("api_key", "").strip()
        persist = data.get("persist", True)

        res = ai_assistant.set_api_key(new_key, persist_to_env=persist)
        return jsonify({
            "success": True,
            "configured": res["configured"],
            "masked_key": res["masked_key"],
            "provider": res.get("provider", ""),
            "model": res.get("model", ""),
            "message": f"API key successfully updated! Active Provider: {res.get('provider', '')} ({res.get('model', '')})" if res["configured"] else "API key cleared. System returned to offline fallback mode."
        })
    except Exception as e:
        return jsonify({"success": False, "error": f"Failed to save API key: {str(e)}"}), 500

@app.route("/api/config/test-key", methods=["POST"])
def test_api_key_endpoint():
    """
    Tests live connection to OpenAI or Google Gemini API with the provided or active key.
    """
    try:
        data = request.get_json(silent=True) or {}
        key_to_test = data.get("api_key")
        result = ai_assistant.test_api_key(key_to_test)
        return jsonify({
            "success": result.get("valid", False),
            "provider": result.get("provider", ""),
            "model": result.get("model", ""),
            "message": result.get("message", ""),
            "error": result.get("error", "")
        })
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/<path:filename>")
def serve_static(filename):
    if filename.startswith("api/"):
        return jsonify({"error": f"API route '/{filename}' not found"}), 404
    file_path = os.path.join(BASE_DIR, filename)
    if os.path.exists(file_path) and os.path.isfile(file_path):
        return send_from_directory(BASE_DIR, filename)
    return jsonify({"error": f"File '{filename}' not found"}), 404

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 3000))
    print("==================================================")
    print(f"[NCC AI Portal] Server Running on Port {port}")
    print(f"[NCC AI Portal] Web UI: http://localhost:{port}/index.html")
    print("[NCC AI Portal] PDF Engine: Ready for Full-Document Optimization")
    print("==================================================")
    app.run(host="0.0.0.0", port=port, debug=False)
