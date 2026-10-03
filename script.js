/**
 * NCC AI Learning Portal - Authentication & Interactive Login Scripts
 * Handles Cadet Login, Registration, Google Single Sign-On, Password Visibility Toggle,
 * and Password Reset.
 */

// =======================================================
// PASSWORD VISIBILITY TOGGLER
// =======================================================

function togglePasswordVisibility(inputId, btn) {
    const input = document.getElementById(inputId);
    if (!input) return;

    if (input.type === "password") {
        input.type = "text";
        if (btn) {
            btn.innerHTML = "🔒";
            btn.setAttribute("title", "Hide password");
        }
    } else {
        input.type = "password";
        if (btn) {
            btn.innerHTML = "👁️";
            btn.setAttribute("title", "Show password");
        }
    }
}

// =======================================================
// INLINE NOTIFICATIONS
// =======================================================

function showAuthAlert(message, type = "error") {
    const alertEl = document.getElementById("authAlert");
    if (alertEl) {
        alertEl.style.display = "flex";
        alertEl.className = `auth-alert ${type}`;
        const icon = type === "success" ? "✅" : (type === "info" ? "ℹ️" : "⚠️");
        alertEl.innerHTML = `<span>${icon}</span> <span>${message}</span>`;
    } else {
        // Fallback to browser alert if no element found
        alert(message);
    }
}

function clearAuthAlert() {
    const alertEl = document.getElementById("authAlert");
    if (alertEl) alertEl.style.display = "none";
}

// =======================================================
// CADET LOGIN
// =======================================================

function login() {
    clearAuthAlert();

    const emailInput = document.getElementById("email");
    const passwordInput = document.getElementById("password");
    const loginBtn = document.getElementById("loginBtn");

    const email = emailInput ? emailInput.value.trim().toLowerCase() : "";
    const password = passwordInput ? passwordInput.value : "";

    if (!email || !password) {
        showAuthAlert("Please enter both Cadet ID / Email and Password.", "error");
        if (emailInput && !email) emailInput.focus();
        else if (passwordInput) passwordInput.focus();
        return;
    }

    // Retrieve registered users from localStorage
    let users = [];
    try {
        users = JSON.parse(localStorage.getItem("ncc_registered_users") || "[]");
    } catch (e) {
        users = [];
    }

    // Include single legacy saved user if valid
    const legacyEmail = (localStorage.getItem("userEmail") || "").trim().toLowerCase();
    const legacyPassword = localStorage.getItem("userPassword") || "";
    const legacyName = localStorage.getItem("userName") || "";

    if (legacyEmail && legacyPassword && !users.some(u => u.email.toLowerCase() === legacyEmail)) {
        users.push({
            name: legacyName || legacyEmail.split("@")[0],
            email: legacyEmail,
            password: legacyPassword
        });
    }

    // Default demo account so first-time users can always test immediately
    if (users.length === 0) {
        users.push({
            name: "Cadet Sharma",
            email: "cadet@ncc.in",
            password: "password123"
        });
        localStorage.setItem("ncc_registered_users", JSON.stringify(users));
    }

    // Find account by matching exact email OR exact username prefix OR Cadet ID
    const user = users.find(u => {
        const uEmail = (u.email || "").toLowerCase();
        const uPrefix = uEmail.includes("@") ? uEmail.split("@")[0] : uEmail;
        const uCadetId = (u.cadetId || "").toLowerCase();
        return uEmail === email || uPrefix === email || (uCadetId && uCadetId === email);
    });

    if (!user) {
        showAuthAlert("No account found with this Cadet ID or Email. Please create an account below.", "error");
        return;
    }

    // Strict Password Match Check (allow google_oauth_auth accounts to log in)
    if (user.password !== password && user.password !== "google_oauth_auth") {
        showAuthAlert("Incorrect Password! Please check your credentials or click 'Forgot Password?'.", "error");
        if (passwordInput) {
            passwordInput.value = "";
            passwordInput.focus();
        }
        return;
    }

    // UI Feedback: Button Spinner
    if (loginBtn) {
        const textSpan = loginBtn.querySelector(".btn-text");
        const spinSpan = loginBtn.querySelector(".btn-spinner");
        if (textSpan && spinSpan) {
            textSpan.style.display = "none";
            spinSpan.style.display = "inline";
        }
    }

    // Save active user session
    const displayName = user.name || (user.email ? user.email.split("@")[0] : "Cadet");
    localStorage.setItem("userName", displayName);
    localStorage.setItem("loggedInUser", user.email);

    // Check remember me
    const rememberMe = document.getElementById("rememberMe");
    if (rememberMe && rememberMe.checked) {
        localStorage.setItem("rememberedCadet", user.email);
    } else {
        localStorage.removeItem("rememberedCadet");
    }

    showAuthAlert(`Welcome back, Cadet ${displayName}! Redirecting to Portal...`, "success");

    setTimeout(() => {
        window.location.href = "dashboard.html";
    }, 600);
}

// =======================================================
// GOOGLE SINGLE SIGN-ON (SSO)
// =======================================================

// =======================================================
// GOOGLE AUTHENTICATION & SINGLE SIGN-ON
// =======================================================

let activeGoogleClientId = "";

async function initGoogleAuth() {
    try {
        const resp = await fetch("/api/config/auth");
        const data = await resp.json();
        if (data.google_client_id) {
            activeGoogleClientId = data.google_client_id;
            setupGoogleIdentityServices(activeGoogleClientId);
        }
    } catch(e) {
        console.warn("Could not check Google Auth config:", e);
    }
}

function setupGoogleIdentityServices(clientId) {
    if (typeof google === "undefined" || !google.accounts || !google.accounts.id) {
        setTimeout(() => setupGoogleIdentityServices(clientId), 400);
        return;
    }

    try {
        google.accounts.id.initialize({
            client_id: clientId,
            callback: handleGoogleCredentialResponse,
            auto_select: false,
            cancel_on_tap_outside: true
        });

        const btnBox = document.getElementById("googleOfficialBtnBox");
        if (btnBox) {
            google.accounts.id.renderButton(btnBox, {
                theme: "filled_blue",
                size: "large",
                text: "continue_with",
                shape: "rectangular",
                width: 320
            });
        }
    } catch (e) {
        console.error("GIS init error:", e);
    }
}

function handleGoogleCredentialResponse(response) {
    if (!response || !response.credential) return;

    try {
        const payload = parseJwt(response.credential);
        if (!payload || !payload.email) {
            showAuthAlert("Could not read original email from Google credential.", "error");
            return;
        }

        const realEmail = payload.email.toLowerCase();
        const realName = payload.name || realEmail.split("@")[0];
        const realPicture = payload.picture || "";

        registerAndLoginRealCadet(realName, realEmail, realPicture, "Google OAuth");
    } catch (e) {
        showAuthAlert("Google Sign-In failed: " + e.message, "error");
    }
}

function parseJwt(token) {
    try {
        const base64Url = token.split('.')[1];
        const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
        const jsonPayload = decodeURIComponent(atob(base64).split('').map(function(c) {
            return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
        }).join(''));
        return JSON.parse(jsonPayload);
    } catch(e) {
        return null;
    }
}

function googleLogin() {
    // If Google GIS client ID is loaded and GIS is available, trigger Google prompt
    if (activeGoogleClientId && typeof google !== "undefined" && google.accounts && google.accounts.id) {
        google.accounts.id.prompt((notification) => {
            if (notification.isNotDisplayed() || notification.isSkippedMoment()) {
                openGoogleModal();
            }
        });
        return;
    }

    openGoogleModal();
}

function openGoogleModal() {
    const modal = document.getElementById("googleAuthModal");
    if (modal) {
        modal.style.display = "flex";
        const emailInput = document.getElementById("originalGoogleEmail");
        if (emailInput) {
            emailInput.focus();
        }
    }
}

function closeGoogleModal() {
    const modal = document.getElementById("googleAuthModal");
    if (modal) modal.style.display = "none";
}

function submitOriginalGoogleLogin() {
    const emailInput = document.getElementById("originalGoogleEmail");
    const nameInput = document.getElementById("originalGoogleName");

    const email = emailInput ? emailInput.value.trim().toLowerCase() : "";
    const name = nameInput ? nameInput.value.trim() : "";

    if (!email || !email.includes("@")) {
        alert("Please enter a valid original Google / Gmail address.");
        if (emailInput) emailInput.focus();
        return;
    }

    const displayName = name || email.split("@")[0].replace(/[\._]/g, " ").replace(/\b\w/g, c => c.toUpperCase());
    closeGoogleModal();
    registerAndLoginRealCadet(displayName, email, "", "Original Google Account");
}

function registerAndLoginRealCadet(name, email, avatar = "", provider = "Google") {
    let users = [];
    try {
        users = JSON.parse(localStorage.getItem("ncc_registered_users") || "[]");
    } catch(e) { users = []; }

    const cleanEmail = email.toLowerCase().trim();
    let existing = users.find(u => (u.email || "").toLowerCase() === cleanEmail);
    if (!existing) {
        existing = {
            name: name,
            email: cleanEmail,
            cadetId: `NCC/${new Date().getFullYear()}/${Math.floor(1000 + Math.random() * 9000)}`,
            password: "google_oauth_auth",
            provider: provider,
            avatar: avatar,
            registeredAt: new Date().toISOString()
        };
        users.push(existing);
        localStorage.setItem("ncc_registered_users", JSON.stringify(users));
    }

    // Set active session with real email and name
    localStorage.setItem("userName", name);
    localStorage.setItem("userEmail", cleanEmail);
    localStorage.setItem("loggedInUser", cleanEmail);
    if (avatar) localStorage.setItem("userAvatar", avatar);

    showAuthAlert(`✅ Verified! Logged in with original account: ${cleanEmail}`, "success");

    setTimeout(() => {
        window.location.href = "dashboard.html";
    }, 600);
}

// =======================================================
// FORGOT PASSWORD
// =======================================================

function forgotPassword() {
    clearAuthAlert();
    const emailPrompt = prompt("🔑 Forgot Password Recovery\n\nEnter your registered Email or Cadet ID:");
    if (!emailPrompt || !emailPrompt.trim()) return;

    const clean = emailPrompt.trim().toLowerCase();
    let users = [];
    try {
        users = JSON.parse(localStorage.getItem("ncc_registered_users") || "[]");
    } catch (e) { users = []; }

    const user = users.find(u => {
        const uEmail = (u.email || "").toLowerCase();
        const uPrefix = uEmail.includes("@") ? uEmail.split("@")[0] : uEmail;
        const uCadetId = (u.cadetId || "").toLowerCase();
        return uEmail === clean || uPrefix === clean || (uCadetId && uCadetId === clean);
    });

    if (user) {
        const newPass = prompt(`Hello Cadet ${user.name || clean}!\n\nEnter your new password (minimum 4 characters):`);
        if (newPass && newPass.trim().length >= 4) {
            user.password = newPass.trim();
            localStorage.setItem("ncc_registered_users", JSON.stringify(users));
            showAuthAlert("Password successfully reset! Please enter your new password to login.", "success");
            const passInput = document.getElementById("password");
            if (passInput) passInput.value = newPass.trim();
            const emailInput = document.getElementById("email");
            if (emailInput) emailInput.value = user.email;
        } else if (newPass) {
            alert("Password must be at least 4 characters long.");
        }
    } else {
        showAuthAlert("No account found with this Cadet ID / Email. Please click 'Create an Account' below.", "error");
    }
}

// =======================================================
// CADET REGISTRATION (CREATE ACCOUNT)
// =======================================================

function createAccount() {
    clearAuthAlert();

    const nameInput = document.getElementById("name") || document.getElementById("signupName");
    const emailInput = document.getElementById("signupEmail") || document.getElementById("email");
    const cadetIdInput = document.getElementById("cadetId");
    const passwordInput = document.getElementById("signupPassword") || document.getElementById("password");
    const confirmInput = document.getElementById("confirmPassword");
    const signupBtn = document.getElementById("signupBtn");

    const name = nameInput ? nameInput.value.trim() : "";
    const email = emailInput ? emailInput.value.trim().toLowerCase() : "";
    const cadetId = cadetIdInput ? cadetIdInput.value.trim().toUpperCase() : "";
    const password = passwordInput ? passwordInput.value : "";
    const confirmPassword = confirmInput ? confirmInput.value : "";

    if (!name || !email || !password) {
        showAuthAlert("Please fill in your Full Name, Email, and Password.", "error");
        return;
    }

    if (password.length < 4) {
        showAuthAlert("Password should be at least 4 characters long.", "error");
        return;
    }

    if (confirmInput && password !== confirmPassword) {
        showAuthAlert("Passwords do not match! Please check and confirm your password.", "error");
        if (confirmInput) {
            confirmInput.value = "";
            confirmInput.focus();
        }
        return;
    }

    // Get existing users
    let users = [];
    try {
        users = JSON.parse(localStorage.getItem("ncc_registered_users") || "[]");
    } catch (e) {
        users = [];
    }

    // Check if email already registered
    if (users.some(u => (u.email || "").toLowerCase() === email)) {
        showAuthAlert("An account with this Email already exists! Please click Login.", "error");
        return;
    }

    // Save new Cadet account
    const newUser = {
        name: name,
        email: email,
        cadetId: cadetId || `NCC/${new Date().getFullYear()}/${Math.floor(1000 + Math.random() * 9000)}`,
        password: password,
        registeredAt: new Date().toISOString()
    };
    users.push(newUser);
    localStorage.setItem("ncc_registered_users", JSON.stringify(users));

    // Update active profile
    localStorage.setItem("userName", name);
    localStorage.setItem("userEmail", email);
    localStorage.setItem("userPassword", password);
    localStorage.setItem("loggedInUser", email);

    // Button Spinner
    if (signupBtn) {
        const textSpan = signupBtn.querySelector(".btn-text");
        const spinSpan = signupBtn.querySelector(".btn-spinner");
        if (textSpan && spinSpan) {
            textSpan.style.display = "none";
            spinSpan.style.display = "inline";
        }
    }

    showAuthAlert(`✅ Account Created Successfully for Cadet ${name}! Redirecting to Portal...`, "success");

    setTimeout(() => {
        window.location.href = "dashboard.html";
    }, 800);
}

// Auto-fill remembered cadet on page load & initialize Google Auth
document.addEventListener("DOMContentLoaded", () => {
    initGoogleAuth();
    const remembered = localStorage.getItem("rememberedCadet");
    const emailInput = document.getElementById("email");
    const rememberMe = document.getElementById("rememberMe");
    if (remembered && emailInput) {
        emailInput.value = remembered;
        if (rememberMe) rememberMe.checked = true;
    }
});