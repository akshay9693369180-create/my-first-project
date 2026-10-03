"""
NCC AI Learning Portal - Universal General-Purpose Conversational AI Engine
Handles all safe user queries including general chat, mathematics, science, programming, history,
translations, essay/application writing, academic studies, and NCC & Defence curriculum.
"""

import os
import re
import json
import urllib.request
import urllib.error
from typing import Dict, List, Any, Optional

def load_env_file(dotenv_path: Optional[str] = None):
    """Loads key-value pairs from .env into os.environ if not already present."""
    if dotenv_path is None:
        dotenv_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.exists(dotenv_path):
        return
    try:
        with open(dotenv_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip("'\"")
                if k and k not in os.environ:
                    os.environ[k] = v
    except Exception as e:
        print(f"[Config] Warning loading .env: {e}")

# Preload environment variables from .env
load_env_file()

class NccAiAssistantEngine:
    def __init__(self):
        self.sessions: Dict[str, List[Dict[str, str]]] = {}
        raw_gemini = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or ""
        raw_openai = os.environ.get("OPENAI_API_KEY") or ""
        if raw_gemini.startswith("sk-") and not raw_openai:
            self.openai_api_key = raw_gemini
            self.gemini_api_key = None
        elif raw_openai.startswith("AIza") and not raw_gemini:
            self.gemini_api_key = raw_openai
            self.openai_api_key = None
        else:
            self.gemini_api_key = raw_gemini or None
            self.openai_api_key = raw_openai or None

    def reload_api_key(self):
        """Reloads API key from environment / .env file."""
        load_env_file()
        raw_gemini = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or ""
        raw_openai = os.environ.get("OPENAI_API_KEY") or ""
        if raw_gemini.startswith("sk-") and not raw_openai:
            self.openai_api_key = raw_gemini
            self.gemini_api_key = None
        elif raw_openai.startswith("AIza") and not raw_gemini:
            self.gemini_api_key = raw_openai
            self.openai_api_key = None
        else:
            self.gemini_api_key = raw_gemini or None
            self.openai_api_key = raw_openai or None
        return self.gemini_api_key or self.openai_api_key

    def set_api_key(self, api_key: str, persist_to_env: bool = True) -> Dict[str, Any]:
        """
        Dynamically updates API key in-memory and optionally persists to .env.
        Auto-routes between OpenAI (sk-...) and Google Gemini.
        """
        clean_key = (api_key or "").strip()
        is_openai = clean_key.startswith("sk-")

        if is_openai:
            self.openai_api_key = clean_key or None
            self.gemini_api_key = None
            os.environ["OPENAI_API_KEY"] = clean_key
            if "GEMINI_API_KEY" in os.environ:
                del os.environ["GEMINI_API_KEY"]
        else:
            self.gemini_api_key = clean_key or None
            self.openai_api_key = None
            if clean_key:
                os.environ["GEMINI_API_KEY"] = clean_key
            elif "GEMINI_API_KEY" in os.environ:
                del os.environ["GEMINI_API_KEY"]
            if "OPENAI_API_KEY" in os.environ:
                del os.environ["OPENAI_API_KEY"]

        if persist_to_env:
            try:
                env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
                lines = []
                if os.path.exists(env_path):
                    with open(env_path, "r", encoding="utf-8") as f:
                        lines = f.readlines()
                new_lines = []
                wrote_key = False
                for line in lines:
                    if line.strip().startswith("GEMINI_API_KEY=") or line.strip().startswith("OPENAI_API_KEY="):
                        if not wrote_key and clean_key:
                            key_var = "OPENAI_API_KEY" if is_openai else "GEMINI_API_KEY"
                            new_lines.append(f'{key_var}="{clean_key}"\n')
                            wrote_key = True
                    else:
                        new_lines.append(line)
                if not wrote_key and clean_key:
                    key_var = "OPENAI_API_KEY" if is_openai else "GEMINI_API_KEY"
                    new_lines.append(f'{key_var}="{clean_key}"\n')
                with open(env_path, "w", encoding="utf-8") as f:
                    f.writelines(new_lines)
            except Exception as e:
                print(f"[Config] Error writing .env: {e}")

        provider_info = self.get_active_provider()
        return {
            "configured": bool(clean_key),
            "masked_key": self.get_masked_key(),
            "provider": provider_info["provider"],
            "model": provider_info["model"]
        }

    # Backward compatibility alias
    def set_gemini_api_key(self, api_key: str, persist_to_env: bool = True) -> Dict[str, Any]:
        return self.set_api_key(api_key, persist_to_env=persist_to_env)

    def get_active_provider(self, key: Optional[str] = None) -> Dict[str, str]:
        check_key = key or self.openai_api_key or self.gemini_api_key or os.environ.get("OPENAI_API_KEY") or os.environ.get("GEMINI_API_KEY") or ""
        if check_key.startswith("sk-"):
            return {"provider": "OpenAI", "model": "gpt-4o-mini", "key": check_key}
        elif check_key:
            return {"provider": "Google Gemini", "model": "gemini-1.5-flash", "key": check_key}
        return {"provider": "Local Fallback", "model": "Rule-Based Engine", "key": ""}

    def get_masked_key(self) -> str:
        """Returns masked API key for safe UI status display."""
        key = self.openai_api_key or self.gemini_api_key or os.environ.get("OPENAI_API_KEY") or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or ""
        if not key:
            return ""
        if len(key) <= 8:
            return "******"
        return key[:6] + "..." + key[-4:]

    def test_api_key(self, api_key: Optional[str] = None) -> Dict[str, Any]:
        """
        Tests whether the provided key or active key works by contacting OpenAI or Google Gemini.
        """
        key_to_test = (api_key or self.openai_api_key or self.gemini_api_key or os.environ.get("OPENAI_API_KEY") or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or "").strip()
        if not key_to_test:
            return {"valid": False, "error": "No API key provided."}

        # 1. Test OpenAI key
        if key_to_test.startswith("sk-"):
            try:
                url = "https://api.openai.com/v1/chat/completions"
                req_data = {
                    "model": "gpt-4o-mini",
                    "messages": [{"role": "user", "content": "OK"}],
                    "max_tokens": 5
                }
                req = urllib.request.Request(
                    url,
                    data=json.dumps(req_data).encode("utf-8"),
                    headers={
                        "Authorization": f"Bearer {key_to_test}",
                        "Content-Type": "application/json"
                    }
                )
                with urllib.request.urlopen(req, timeout=10) as response:
                    res_json = json.loads(response.read().decode("utf-8"))
                    if "choices" in res_json and len(res_json["choices"]) > 0:
                        return {
                            "valid": True,
                            "provider": "OpenAI",
                            "model": "gpt-4o-mini",
                            "message": "Connection verified! OpenAI (GPT-4o-mini) is active and working."
                        }
                    return {"valid": False, "provider": "OpenAI", "error": "No choices returned by OpenAI."}
            except urllib.error.HTTPError as e:
                err_body = {}
                try:
                    err_body = json.loads(e.read().decode("utf-8"))
                except Exception:
                    pass
                msg = err_body.get("error", {}).get("message", f"HTTP Error {e.code}: {e.reason}")
                code = err_body.get("error", {}).get("code", "")
                if e.code == 429 or code == "credit_balance_exhausted":
                    return {
                        "valid": False,
                        "provider": "OpenAI",
                        "error": "OpenAI Quota Exhausted: This key has no billing credits remaining. Please add credits at platform.openai.com, OR get a 100% Free Gemini API Key at https://aistudio.google.com/app/apikey"
                    }
                return {"valid": False, "provider": "OpenAI", "error": f"OpenAI Error: {msg}"}
            except Exception as e:
                return {"valid": False, "provider": "OpenAI", "error": f"OpenAI Error: {str(e)}"}

        # 2. Test Google Gemini key
        try:
            url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={key_to_test}"
            req_data = {
                "contents": [{"role": "user", "parts": [{"text": "Hello, respond with single word: OK"}]}],
                "generationConfig": {"maxOutputTokens": 10, "temperature": 0.0}
            }
            req = urllib.request.Request(
                url,
                data=json.dumps(req_data).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.loads(response.read().decode("utf-8"))
                candidates = result.get("candidates", [])
                if candidates:
                    return {
                        "valid": True,
                        "provider": "Google Gemini",
                        "model": "gemini-1.5-flash",
                        "message": "Connection verified! Google Gemini 1.5 Flash is active."
                    }
                return {"valid": False, "provider": "Google Gemini", "error": "No candidates returned by Gemini API."}
        except urllib.error.HTTPError as e:
            err_msg = f"HTTP Error {e.code}: {e.reason}"
            try:
                err_body = json.loads(e.read().decode("utf-8"))
                if "error" in err_body and "message" in err_body["error"]:
                    err_msg = err_body["error"]["message"]
            except Exception:
                pass
            return {"valid": False, "provider": "Google Gemini", "error": err_msg}
        except Exception as e:
            return {"valid": False, "provider": "Google Gemini", "error": str(e)}



    def detect_language(self, text: str, requested_lang: str = "auto") -> str:
        """
        Detects prompt language across English, Hindi, Hinglish, Punjabi, Bengali, Marathi,
        Gujarati, Tamil, Telugu, Kannada, Malayalam, and Urdu, or respects requested_lang override.
        """
        if requested_lang and requested_lang.lower() not in ["auto", "auto detect"]:
            return requested_lang.lower()

        # Regional Indic Script Checks
        if sum(1 for c in text if '\u0B80' <= c <= '\u0BFF') >= 2:
            return "tamil"
        if sum(1 for c in text if '\u0C00' <= c <= '\u0C7F') >= 2:
            return "telugu"
        if sum(1 for c in text if '\u0C80' <= c <= '\u0CFF') >= 2:
            return "kannada"
        if sum(1 for c in text if '\u0D00' <= c <= '\u0D7F') >= 2:
            return "malayalam"
        if sum(1 for c in text if '\u0A00' <= c <= '\u0A7F') >= 2:
            return "punjabi"
        if sum(1 for c in text if '\u0980' <= c <= '\u09FF') >= 2:
            return "bengali"
        if sum(1 for c in text if '\u0A80' <= c <= '\u0AFF') >= 2:
            return "gujarati"
        if sum(1 for c in text if '\u0600' <= c <= '\u06FF') >= 2:
            return "urdu"

        # Check Devanagari Unicode range (0900-097F)
        devanagari_chars = sum(1 for c in text if '\u0900' <= c <= '\u097F')
        if devanagari_chars > 3:
            return "hindi"

        text_lower = text.lower()
        hinglish_markers = [
            "kya", "hai", "hain", "kaise", "kahan", "kitna", "kitne", "hota", "hoti", "hote",
            "batao", "samjhao", "iska", "iski", "iske", "kaun", "kise", "kinhe", "me", "mein",
            "aur", "karo", "karna", "chahiye", "likho", "padho", "kisi", "kyu", "kyun", "hoga",
            "karega", "karte", "bad", "pehle", "sath", "se", "ko", "par", "ke", "ki", "ka"
        ]
        words = re.findall(r'\b[a-zA-Z]+\b', text_lower)
        if words:
            hinglish_count = sum(1 for w in words if w in hinglish_markers)
            if hinglish_count >= 1 or (len(words) <= 4 and hinglish_count >= 1):
                return "hinglish"

        return "english"

    def extract_recent_topic(self, history: List[Dict[str, str]]) -> str:
        """
        Extracts the subject/topic being discussed from conversation history for follow-ups.
        """
        for item in reversed(history):
            content = item.get("content", "").lower()
            if any(k in content for k in ["slr", "7.62", "self loading rifle"]):
                return "slr"
            if any(k in content for k in ["insas", "5.56"]):
                return "insas"
            if any(k in content for k in [".22", "deluxe", "twenty two"]):
                return "deluxe_22"
            if any(k in content for k in ["drill", "savdhan", "vishram", "salute"]):
                return "drill"
            if any(k in content for k in ["compass", "map reading", "grid reference", "gr", "bearing"]):
                return "map_reading"
            if any(k in content for k in ["b certificate", "b cert", "b pariksha"]):
                return "b_cert"
            if any(k in content for k in ["c certificate", "c cert", "c pariksha"]):
                return "c_cert"
            if any(k in content for k in ["python", "javascript", "java", "code"]):
                return "programming"
            if any(k in content for k in ["physics", "gravity", "motion", "newton"]):
                return "physics"
            if any(k in content for k in ["chemistry", "photosynthesis", "h2o", "acid"]):
                return "chemistry"
        return ""

    def query_external_llm(self, prompt: str, history: List[Dict[str, str]], doc_context: str = "", requested_lang: str = "auto", api_key_override: Optional[str] = None) -> Optional[str]:
        """
        Queries OpenAI or Gemini API if key is configured, securely on the backend.
        Auto-routes between OpenAI (sk-...) and Google Gemini.
        """
        active_key = api_key_override or self.openai_api_key or self.gemini_api_key or os.environ.get("OPENAI_API_KEY") or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        if not active_key:
            return None

        lang = self.detect_language(prompt, requested_lang)
        system_instruction = (
            "You are a friendly, highly intelligent general-purpose conversational AI agent. "
            "You answer any question accurately, including general greetings, everyday conversations, mathematics, science, physics, chemistry, programming (Python, Java, JavaScript, C++, HTML/CSS, SQL), history, translations, "
            "essay/application writing, academic studies, career guidance, as well as comprehensive National Cadet Corps (NCC) syllabus and defence studies. "
            f"Respond in the requested/detected language: {lang}. "
            "Do NOT force NCC references or military greetings into general non-NCC questions. "
            "Format responses cleanly using markdown headings, bullet points, numbered lists, and code blocks where appropriate."
        )

        # 1. Route to OpenAI if key starts with sk-
        if active_key.startswith("sk-"):
            try:
                messages = [{"role": "system", "content": system_instruction}]
                if doc_context:
                    messages.append({
                        "role": "system",
                        "content": f"[STUDY DOCUMENT EXCERPTS]:\n{doc_context[:3000]}\nPlease reference this document if relevant to the query."
                    })
                for turn in history[-6:]:
                    messages.append({
                        "role": "user" if turn.get("role") == "user" else "assistant",
                        "content": turn.get("content", "")
                    })
                messages.append({"role": "user", "content": prompt})

                req_data = {
                    "model": "gpt-4o-mini",
                    "messages": messages,
                    "temperature": 0.4,
                    "max_tokens": 1000
                }
                req = urllib.request.Request(
                    "https://api.openai.com/v1/chat/completions",
                    data=json.dumps(req_data).encode("utf-8"),
                    headers={
                        "Authorization": f"Bearer {active_key}",
                        "Content-Type": "application/json"
                    }
                )
                with urllib.request.urlopen(req, timeout=14) as response:
                    result = json.loads(response.read().decode("utf-8"))
                    choices = result.get("choices", [])
                    if choices:
                        return choices[0].get("message", {}).get("content", "")
            except Exception as e:
                print(f"[AI Assistant] OpenAI API error / fallback: {e}")
            return None

        # 2. Route to Google Gemini
        try:
            contents = []
            if doc_context:
                contents.append({
                    "role": "user",
                    "parts": [{"text": f"[STUDY DOCUMENT EXCERPTS]:\n{doc_context[:3000]}\n\nPlease use this context if relevant."}]
                })
                contents.append({
                    "role": "model",
                    "parts": [{"text": "Understood. I will reference this study document."}]
                })

            for turn in history[-6:]:
                role = "user" if turn.get("role") == "user" else "model"
                contents.append({
                    "role": role,
                    "parts": [{"text": turn.get("content", "")}]
                })

            contents.append({
                "role": "user",
                "parts": [{"text": prompt}]
            })

            url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={active_key}"
            req_data = {
                "contents": contents,
                "systemInstruction": {"parts": [{"text": system_instruction}]},
                "generationConfig": {
                    "temperature": 0.4,
                    "maxOutputTokens": 1000
                }
            }

            req = urllib.request.Request(
                url,
                data=json.dumps(req_data).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=12) as response:
                result = json.loads(response.read().decode("utf-8"))
                candidates = result.get("candidates", [])
                if candidates:
                    parts = candidates[0].get("content", {}).get("parts", [])
                    if parts:
                        return parts[0].get("text", "")
        except Exception as e:
            print(f"[AI Assistant] External LLM error / fallback: {e}")

        return None

    def search_document(self, query: str, doc_text: str) -> Dict[str, Any]:
        """
        Searches uploaded document text for user query keywords.
        """
        if not doc_text or len(doc_text.strip()) < 15:
            return {"found": False, "excerpt": "", "is_doc_query": False}

        q_lower = query.lower()
        is_explicit_doc_query = (
            bool(doc_text) or 
            any(w in q_lower for w in ["document", "pdf", "file", "notes", "is this in", "iss document me", "notice", "text", "uploaded"])
        )
        
        words = [w for w in re.findall(r'\b[a-zA-Z0-9]{3,}\b', q_lower) if w not in ["what", "when", "where", "which", "this", "that", "from", "with", "have", "kya", "hai", "hain", "kaise", "is", "are", "held", "the", "and"]]
        
        paragraphs = [p.strip() for p in doc_text.split("\n") if len(p.strip()) > 15]
        scored_paras = []
        for p in paragraphs:
            p_lower = p.lower()
            score = sum(1 for w in words if w in p_lower)
            if score > 0:
                scored_paras.append((score, p))

        scored_paras.sort(key=lambda x: x[0], reverse=True)
        if scored_paras and (scored_paras[0][0] >= 1):
            return {
                "found": True,
                "excerpt": scored_paras[0][1],
                "all_top": [p for _, p in scored_paras[:3]],
                "is_doc_query": is_explicit_doc_query
            }

        return {
            "found": False,
            "excerpt": "",
            "is_doc_query": is_explicit_doc_query
        }

    def generate_response(self, prompt: str, history: List[Dict[str, str]] = None, doc_text: str = "", doc_name: str = "", requested_lang: str = "auto", api_key: Optional[str] = None) -> Dict[str, Any]:
        """
        Main response generation pipeline with context, language adaptation,
        and grounding across general conversational queries & specialized knowledge.
        """
        history = history or []
        lang = self.detect_language(prompt, requested_lang)
        prompt_lower = prompt.lower().strip()
        recent_topic = self.extract_recent_topic(history)

        # 1. Check Document Reference (RAG)
        doc_search = self.search_document(prompt, doc_text)
        
        if doc_search["is_doc_query"] and not doc_search["found"] and bool(doc_text):
            if lang == "hindi":
                return {
                    "answer": f"⚠️ **दस्तावेज़ में जानकारी उपलब्ध नहीं है:** आपके अपलोड किए गए दस्तावेज़ (**{doc_name or 'Uploaded File'}**) में इससे संबंधित विवरण नहीं मिला।",
                    "doc_referenced": True,
                    "doc_name": doc_name,
                    "is_grounded": False
                }
            elif lang == "hinglish":
                return {
                    "answer": f"⚠️ **Document me yeh jankari uplabdh nahi hai:** Aapke upload kiye gaye study material (**{doc_name or 'Uploaded File'}**) me is question ka detail nahi mila.",
                    "doc_referenced": True,
                    "doc_name": doc_name,
                    "is_grounded": False
                }
            else:
                return {
                    "answer": f"⚠️ **Information Not Available in Document:** The requested details are not mentioned in your uploaded document (**{doc_name or 'Uploaded File'}**).",
                    "doc_referenced": True,
                    "doc_name": doc_name,
                    "is_grounded": False
                }

        # 2. Try External LLM if configured
        external_reply = self.query_external_llm(prompt, history, doc_search.get("excerpt", ""), requested_lang, api_key_override=api_key)
        if external_reply:
            return {
                "answer": external_reply,
                "doc_referenced": doc_search.get("found", False),
                "doc_name": doc_name if doc_search.get("found", False) else "",
                "is_grounded": doc_search.get("found", False),
                "language": lang
            }

        # 3. Intelligent General Conversational & Knowledge Engine
        answer = self.synthesize_knowledge_answer(prompt, prompt_lower, lang, recent_topic, doc_search, doc_name)

        return {
            "answer": answer,
            "doc_referenced": doc_search.get("found", False),
            "doc_name": doc_name if doc_search.get("found", False) else "",
            "is_grounded": doc_search.get("found", False),
            "language": lang
        }

    def match_kw(self, q: str, keywords: List[str]) -> bool:
        """Helper to match exact word boundaries to avoid false substring matches."""
        q_clean = re.sub(r'[^\w\s]', ' ', q.lower())
        for kw in keywords:
            if kw in q_clean or re.search(r'\b' + re.escape(kw) + r'\b', q_clean, re.IGNORECASE):
                return True
        return False

    def evaluate_math(self, prompt: str) -> Optional[str]:
        """Evaluates arithmetic expressions inside queries like '25 × 8 kitna hai', '2 + 2', 'solve 50 * 12'."""
        clean = prompt.lower().replace("x", "*").replace("×", "*").replace("÷", "/")
        # Extract pure mathematical expression
        match = re.search(r'(\d+(?:\.\d+)?\s*[\+\-\*\/\%]\s*\d+(?:\.\d+)?(?:\s*[\+\-\*\/]\s*\d+(?:\.\d+)?)*)', clean)
        if match:
            expr = match.group(1).strip()
            try:
                if any(c in expr for c in ['import', 'eval', 'exec', '__']):
                    return None
                val = eval(expr, {"__builtins__": None}, {})
                if isinstance(val, (int, float)):
                    if isinstance(val, float) and val.is_integer():
                        val = int(val)
                    return f"**{val}**"
            except Exception:
                pass
        return None

    def synthesize_knowledge_answer(self, raw_prompt: str, q: str, lang: str, recent_topic: str, doc_search: Dict[str, Any], doc_name: str) -> str:
        """
        Synthesizes natural conversational answers across greetings, math, programming,
        science, physics, chemistry, history, translations, writing, general knowledge, and NCC syllabus.
        """
        # Grounded Document Reference takes precedence if found
        if doc_search.get("found"):
            excerpt = doc_search["excerpt"]
            if lang == "hinglish":
                return f"📄 **Aapke Document ({doc_name or 'Uploaded File'}) se reference:**\n\n> \"{excerpt}\"\n\n**Explanation:** Yeh section aapke sawal se direct match karta hai."
            elif lang == "hindi":
                return f"📄 **आपके दस्तावेज़ ({doc_name or 'अपलोड की गई फ़ाइल'}) से प्राप्त उत्तर:**\n\n> \"{excerpt}\"\n\n**व्याख्या:** यह अंश आपके प्रश्न का सीधा उत्तर प्रदान करता है।"
            else:
                return f"📄 **Reference Answer from your Document ({doc_name or 'Uploaded File'}):**\n\n> \"{excerpt}\"\n\n**Summary:** This section from the document directly answers your query."

        # --- 1. GREETINGS & CASUAL CONVERSATION ---
        greetings = ["hello", "hlo", "hi", "hey", "namaste", "namaskar", "pranam", "sat sri akal", "vanakkam", "kem cho", "adaab", "salaam"]
        if any(q.strip() == g or q.strip().startswith(g + " ") or q.strip().endswith(" " + g) for g in greetings):
            if lang == "hindi":
                return "नमस्ते! 👋 मैं आपकी क्या सहायता कर सकता हूँ?"
            elif lang == "hinglish":
                return "Hello! 👋 Main aapki kya help kar sakta hoon?"
            elif lang == "punjabi":
                return "ਸਤਿ ਸ਼੍ਰੀ ਅਕਾਲ! 👋 ਮੈਂ ਤੁਹਾਡੀ ਕੀ ਮਦਦ ਕਰ ਸਕਦਾ ਹਾਂ?"
            elif lang == "tamil":
                return "வணக்கம்! 👋 நான் உங்களுக்கு எவ்வாறு உதவ முடியும்?"
            elif lang == "telugu":
                return "నమస్కారం! 👋 నేను మీకు ఎలా సహాయపడగలను?"
            elif lang == "bengali":
                return "হ্যালো! 👋 আমি আপনাকে কীভাবে সাহায্য করতে পারি?"
            elif lang == "marathi":
                return "नमस्कार! 👋 मी तुम्हाला कशी मदत करू शकतो?"
            elif lang == "gujarati":
                return "નમસ્તે! 👋 હું તમને કેવી રીતે મદદ કરી શકું?"
            elif lang == "urdu":
                return "سلام! 👋 میں آپ کی کیا مدد کر سکتا ہوں؟"
            elif lang == "kannada":
                return "ನಮಸ್ಕಾರ! 👋 ನಾನು ನಿಮಗೆ ಹೇಗೆ ಸಹಾಯ ಮಾಡಲಿ?"
            elif lang == "malayalam":
                return "നമസ്കാരം! 👋 ഞാൻ നിങ്ങളെ എങ്ങനെ സഹായിക്കണം?"
            else:
                return "Hello! How can I help you?"

        # --- 2. HOW ARE YOU / STATUS ---
        if any(k in q for k in ["how are you", "kaise ho", "kese ho", "kasa ahes", "kya haal", "how r u"]):
            if lang == "hindi":
                return "मैं बिल्कुल ठीक हूँ, धन्यवाद! आप कैसे हैं? आज मैं आपकी क्या मदद कर सकता हूँ?"
            elif lang == "hinglish":
                return "Main badhiya hoon! Aap bataiye, aaj main aapki kya help kar sakta hoon?"
            elif lang == "punjabi":
                return "ਮੈਂ ਬਿਲਕੁਲ ਠੀਕ ਹਾਂ, ਧੰਨਵਾਦ! ਤੁਸੀਂ ਕਿਵੇਂ ਹੋ?"
            else:
                return "I'm doing great, thank you for asking! How can I help you today?"

        if any(k in q for k in ["thank you", "thanks", "dhanyavaad", "dhanvaad", "shukriya"]):
            return "You're very welcome! Feel free to ask if you have any more questions."

        # --- 3. MATHEMATICAL CALCULATIONS ---
        math_res = self.evaluate_math(raw_prompt)
        if math_res:
            return math_res

        # --- 4. TRANSLATIONS ---
        if "translate" in q or "in hindi" in q or "in punjabi" in q or "in english" in q:
            if "i am happy" in q:
                if "hindi" in q:
                    return "मैं खुश हूँ।"
                elif "punjabi" in q:
                    return "ਮੈਂ ਖੁਸ਼ ਹਾਂ।"
            if "hello" in q:
                if "hindi" in q:
                    return "नमस्ते (Namaste)"
                elif "punjabi" in q:
                    return "ਸਤਿ ਸ਼੍ਰੀ ਅਕਾਲ (Sat Sri Akal)"
            if "thank you" in q:
                if "punjabi" in q:
                    return "ਧੰਨਵਾਦ (Dhanvaad)"
                elif "hindi" in q:
                    return "धन्यवाद (Dhanyavaad)"

        # --- 5. PUNJABI SPECIFIC RESPONSES ---
        if lang == "punjabi" and ("ਮੈਨੂੰ" in q or "ਪੰਜਾਬੀ" in q or "ਜਵਾਬ" in q):
            return "ਜੀ ਬਿਲਕੁਲ! ਤੁਸੀਂ ਜੋ ਵੀ ਪੁੱਛਣਾ ਚਾਹੁੰਦੇ ਹੋ, ਪੁੱਛ ਸਕਦੇ ਹੋ। ਮੈਂ ਤੁਹਾਡੀ ਹਰ ਸਵਾਲ ਵਿੱਚ ਮਦਦ ਕਰਨ ਲਈ ਤਿਆਰ ਹਾਂ।"

        # --- 6. PROGRAMMING & COMPUTER SCIENCE ---
        if self.match_kw(q, ["python", "what is python", "python kya hai"]):
            if lang == "hindi" or lang == "hinglish":
                return (
                    "🐍 **Python Programming Language:**\n\n"
                    "Python ek versatile, high-level aur easy-to-learn programming language hai jise Guido van Rossum ne 1991 me banaya tha.\n\n"
                    "📌 **Main Uses:**\n"
                    "• Web Development (Django, Flask)\n"
                    "• Data Science & Artificial Intelligence (AI)\n"
                    "• Machine Learning & Automation Scripts\n\n"
                    "```python\n"
                    "# Example code:\n"
                    "print('Hello, World!')\n"
                    "```"
                )
            else:
                return (
                    "🐍 **Python Programming Language:**\n\n"
                    "Python is a high-level, interpreted programming language known for its clean syntax and readability.\n\n"
                    "📌 **Key Applications:**\n"
                    "• Web Development (Django, Flask)\n"
                    "• Data Science, AI, and Machine Learning\n"
                    "• Automation & Scripting\n\n"
                    "```python\n"
                    "# Example code:\n"
                    "print('Hello, World!')\n"
                    "```"
                )

        if self.match_kw(q, ["javascript", "what is javascript"]):
            return (
                "⚡ **JavaScript (JS):**\n\n"
                "JavaScript is a lightweight, interpreted programming language primarily used to make web pages interactive and dynamic. "
                "Along with HTML and CSS, JavaScript is a core technology of the World Wide Web.\n\n"
                "📌 **Usage:** Front-end (React, Vue, Angular) and Back-end (Node.js)."
            )

        if self.match_kw(q, ["java", "what is java"]):
            return (
                "☕ **Java Programming Language:**\n\n"
                "Java is a class-based, object-oriented programming language developed by Sun Microsystems in 1995. "
                "It follows the **WORA (Write Once, Run Anywhere)** principle using the JVM.\n\n"
                "📌 **Usage:** Android App Development, Enterprise Software, and Cloud Systems."
            )

        if self.match_kw(q, ["add two numbers", "function to add"]):
            return (
                "💻 **Python Function to Add Two Numbers:**\n\n"
                "```python\n"
                "def add(a, b):\n"
                "    return a + b\n\n"
                "print('Sum:', add(10, 20))  # Output: Sum: 30\n"
                "```"
            )

        # --- 7. SCIENCE (PHYSICS, CHEMISTRY, BIOLOGY) ---
        if self.match_kw(q, ["photosynthesis", "what is photosynthesis"]):
            return (
                "🌿 **Photosynthesis:**\n\n"
                "Photosynthesis is the biological process by which green plants use sunlight, carbon dioxide ($CO_2$), and water ($H_2O$) to produce oxygen ($O_2$) and energy in the form of glucose ($C_6H_{12}O_6$).\n\n"
                "🧪 **Formula:**\n"
                "$$6CO_2 + 6H_2O \\xrightarrow{\\text{Sunlight}} C_6H_{12}O_6 + 6O_2$$"
            )

        if self.match_kw(q, ["gravity", "what is gravity"]):
            return (
                "🌌 **Gravity:**\n\n"
                "Gravity is the fundamental force of attraction that pulls objects with mass towards each other. "
                "On Earth, gravity accelerates falling objects at approximately **9.8 m/s²**."
            )

        if self.match_kw(q, ["newton's laws", "laws of motion"]):
            return (
                "⚛️ **Newton's Three Laws of Motion:**\n\n"
                "1. **First Law (Inertia):** An object remains at rest or in uniform motion unless acted upon by an external force.\n"
                "2. **Second Law ($F = ma$):** Force equals mass times acceleration.\n"
                "3. **Third Law (Action & Reaction):** For every action, there is an equal and opposite reaction."
            )

        if self.match_kw(q, ["water formula", "chemical formula of water"]):
            return "🧪 The chemical formula of water is **$H_2O$** (two Hydrogen atoms and one Oxygen atom)."

        # --- 8. ESSAYS, APPLICATIONS & WRITING ---
        if self.match_kw(q, ["leave application", "write an application", "application for leave"]):
            return (
                "📝 **Sample Application for Leave:**\n\n"
                "To,\n"
                "The Principal / Manager,\n"
                "[School / College / Office Name]\n\n"
                "**Subject:** Application for Sick Leave\n\n"
                "Respected Sir/Madam,\n\n"
                "I am writing to inform you that I am unwell due to fever and unable to attend classes/office for 2 days from [Date] to [Date]. Kindly grant me leave for these days.\n\n"
                "Thanking you.\n\n"
                "Yours faithfully,\n"
                "[Your Name]\n"
                "[Roll No. / Designation]"
            )

        # --- 9. GENERAL KNOWLEDGE & HISTORY ---
        if self.match_kw(q, ["capital of india", "india capital"]):
            return "🏛️ The capital of India is **New Delhi**."

        if self.match_kw(q, ["independence day", "1947"]):
            return "🇮🇳 India gained independence from British rule on **15th August 1947**."

        # --- 10. NCC & DEFENCE SYLLABUS ---
        if self.match_kw(q, ["motto", "full form", "aim", "cardinal", "establishment", "formed", "1948", "history of ncc", "what is ncc", "about ncc", "ncc motto", "ncc kya hai", "kya hai ncc"]):
            if lang == "hinglish":
                return (
                    "NCC ka full form **National Cadet Corps (राष्ट्रीय कैडेट कोर)** hai.\n\n"
                    "🎖️ **NCC Core Facts:**\n\n"
                    "• **Full Form:** National Cadet Corps\n"
                    "• **Motto:** **'Unity and Discipline' (एकता और अनुशासन)**\n"
                    "• **Established:** **16 July 1948** under National Cadet Corps Act XXXI of 1948.\n"
                    "• **Headquarters:** New Delhi.\n"
                    "• **3 Cardinal Rules of Discipline:**\n"
                    "  1. Obey with a smile.\n"
                    "  2. Be punctual.\n"
                    "  3. Make no excuses and tell no lies."
                )
            elif lang == "hindi":
                return (
                    "🎖️ **राष्ट्रीय कैडेट कोर (NCC) से जुड़े मुख्य तथ्य:**\n\n"
                    "• **पूरा नाम:** National Cadet Corps (राष्ट्रीय कैडेट कोर)\n"
                    "• **आदर्श वाक्य (Motto):** **'एकता और अनुशासन' (Unity and Discipline)**\n"
                    "• **स्थापना:** **16 जुलाई 1948**\n"
                    "• **मुख्यालय:** नई दिल्ली\n"
                    "• **अनुशासन के 3 कार्डिनल नियम:**\n"
                    "  1. मुस्कुराहट के साथ आज्ञा का पालन करें।\n"
                    "  2. समय के पाबंद रहें।\n"
                    "  3. कोई बहाना न बनाएं और झूठ न बोलें।"
                )
            else:
                return (
                    "🎖️ **National Cadet Corps (NCC) Overview:**\n\n"
                    "• **Full Form:** National Cadet Corps\n"
                    "• **Motto:** **'Unity and Discipline' (एकता और अनुशासन)** — adopted 23 December 1957.\n"
                    "• **Established:** **16 July 1948** under the National Cadet Corps Act XXXI of 1948.\n"
                    "• **Headquarters:** New Delhi (headed by Director General NCC).\n"
                    "• **Three Cardinal Rules of Discipline:**\n"
                    "  1. Obey with a smile.\n"
                    "  2. Be punctual.\n"
                    "  3. Make no excuses and tell no lies.\n"
                    "• **Core Aims:** To develop character, comradeship, discipline, leadership, secular outlook, spirit of adventure, and ideals of selfless service among youth."
                )

        # Contextual Follow-up resolution for SLR / INSAS / Drill / Map Reading
        is_followup = self.match_kw(q, ["iska", "iski", "iske", "its", "their", "more about it", "aur batao", "explain more", "kargar range", "effective range", "magazine", "capacity", "uses", "fayde", "when was it established", "who is eligible"])
        target_subject = recent_topic if (is_followup and recent_topic) else ""

        if self.match_kw(q, ["slr", "7.62", "self loading"]) or target_subject == "slr":
            return (
                "🎯 **7.62mm SLR (Self Loading Rifle) Technical Specifications:**\n\n"
                "• **Caliber:** 7.62 mm\n"
                "• **Effective Range:** 275 Meters (300 Yards)\n"
                "• **Magazine Capacity:** 20 Rounds\n"
                "• **Weight (Empty):** 4.4 kg | **Loaded:** 5.1 kg\n"
                "• **Muzzle Velocity:** 2700 ft/sec (815 m/sec)\n"
                "• **Operation:** Gas Operated, Semi-Automatic"
            )

        if self.match_kw(q, ["insas", "5.56"]):
            return (
                "🔫 **5.56mm INSAS Rifle Specifications:**\n\n"
                "• **Caliber:** 5.56 mm\n"
                "• **Effective Range:** 400 Meters\n"
                "• **Magazine Capacity:** 20 Rounds (Transparent Polymer)\n"
                "• **Weight:** 4.1 kg (Lighter than SLR)\n"
                "• **Firing Mode:** Single Shot & 3-Round Burst (TRB)"
            )

        if self.match_kw(q, ["drill", "savdhan", "vishram"]):
            return (
                "💂 **Drill Fundamentals & Key Angles:**\n\n"
                "• **Aim of Drill:** To instill discipline, alertness, self-confidence, and teamwork.\n"
                "• **Savdhan Position:** Feet together forming a **30-degree angle** at heels.\n"
                "• **Vishram Position:** Heels separated by **12 inches (30 cm)**; hands locked behind back.\n"
                "• **Tej Chal (Quick March):** 120 paces per minute (Pace length: 30 inches)."
            )

        if self.match_kw(q, ["c certificate", "b certificate", "entry benefits", "special entry"]):
            return (
                "🏅 **NCC B & C Certificate Entry Advantages:**\n\n"
                "1. **NCC Special Entry (Indian Army):** 'C' Certificate holders with 'A' or 'B' grading skip UPSC CDS written examination and qualify directly for 5-day SSB interview!\n"
                "2. **CAPF & Police Recruitment:** Bonus marks awarded in CRPF, BSF, CISF, ITBP, and State Police recruitment exams."
            )

        # --- 11. DYNAMIC GENERAL CONVERSATIONAL FALLBACK ---
        # Never force NCC! Reply directly and naturally based on the user's question topic.
        if lang == "hindi":
            return (
                f"**विषय:** '{raw_prompt}'\n\n"
                f"मैं इस प्रश्न का उत्तर देने में आपकी पूरी सहायता करूँगा। क्या आप इससे संबंधित कोई विशिष्ट जानकारी, चरण-दर-चरण व्याख्या या उदाहरण चाहते हैं?"
            )
        elif lang == "hinglish":
            return (
                f"**Topic:** '{raw_prompt}'\n\n"
                f"Main is question me aapki poori help karne ke liye tayyar hoon. Is topic par koi specific detail, example ya explanation chahiye toh batayein!"
            )
        else:
            return (
                f"Here is information regarding: **'{raw_prompt}'**\n\n"
                f"I am ready to assist you with this topic! Please feel free to ask for any specific details, step-by-step breakdown, or examples."
            )
