let bQuestions = [];
let bQuestionIndex = 0;
let bScore = 0;
let bTopic = "";


/* =========================
   START B CERTIFICATE QUIZ
========================= */

function startBQuiz(topic) {

    if (typeof questionBank === "undefined") {
        alert("question.js load nahi hua!");
        return;
    }

    // Topic name ko questionBank ke actual name se match karo
    const topicMap = {
        "NCC General Knowledge": "General_Knowledge",
        "NCC Organisation & History": "Organisation_Administration",
        "National Integration": "National_Integration"
    };

    const actualTopic = topicMap[topic];

    if (
        !questionBank.B_Certificate ||
        !questionBank.B_Certificate[actualTopic]
    ) {
        alert("Is topic ke questions nahi mile: " + topic);
        console.log(questionBank.B_Certificate);
        return;
    }

    bQuestions = questionBank.B_Certificate[actualTopic];

    bQuestionIndex = 0;
    bScore = 0;
    bTopic = topic;

    const area = document.getElementById("bQuizArea");

    if (!area) {
        alert("bQuizArea nahi mila!");
        return;
    }

    area.style.display = "block";

    document.getElementById("bQuizTitle").innerText =
        "📚 " + topic + " Practice";

    showBQuestion();

    area.scrollIntoView({
        behavior: "smooth"
    });
}


/* =========================
   SHOW QUESTION
========================= */

function showBQuestion() {

    if (bQuestionIndex >= bQuestions.length) {
        showBResult();
        return;
    }

    const q = bQuestions[bQuestionIndex];

    const questionBox =
        document.getElementById("bQuestion");

    const optionsBox =
        document.getElementById("bOptions");

    const resultBox =
        document.getElementById("bResult");

    const nextButton =
        document.getElementById("bNextBtn");


    questionBox.innerHTML = `
        <h3>
            Question ${bQuestionIndex + 1}
            / ${bQuestions.length}
        </h3>

        <p style="font-size:18px; font-weight:bold;">
            ${q.question}
        </p>
    `;


    optionsBox.innerHTML = q.options.map((option, index) => {

        return `
            <button
                type="button"
                class="b-option"
                onclick="checkBAnswer(${index})">

                ${String.fromCharCode(65 + index)}.
                ${option}

            </button>
        `;

    }).join("");


    resultBox.innerHTML = "";

    nextButton.style.display = "none";
}


/* =========================
   CHECK ANSWER
========================= */

function checkBAnswer(selectedIndex) {

    const q = bQuestions[bQuestionIndex];

    const resultBox =
        document.getElementById("bResult");

    const buttons =
        document.querySelectorAll("#bOptions .b-option");


    // All options disable and highlight
    buttons.forEach((button, idx) => {
        button.disabled = true;
        if (idx === q.answer) {
            button.classList.add("correct-option");
        } else if (idx === selectedIndex) {
            button.classList.add("wrong-option");
        }
    });

    if (typeof incrementSolvedCount === "function") {
        incrementSolvedCount();
    }


    if (selectedIndex === q.answer) {

        bScore++;

        resultBox.innerHTML = `
            <div class="answer-box correct">

                <h3>✅ Correct Answer!</h3>

                <p>
                    ${q.explanation}
                </p>

            </div>
        `;

    } else {

        resultBox.innerHTML = `
            <div class="answer-box wrong">

                <h3>❌ Wrong Answer</h3>

                <p>
                    <b>Correct Answer:</b>
                    ${q.options[q.answer]}
                </p>

                <p>
                    ${q.explanation}
                </p>

            </div>
        `;
    }


    document.getElementById("bNextBtn").style.display =
        "block";
}


/* =========================
   NEXT QUESTION
========================= */

function nextBQuestion() {

    bQuestionIndex++;

    showBQuestion();
}


/* =========================
   RESULT
========================= */

function showBResult() {

    const questionBox =
        document.getElementById("bQuestion");

    const optionsBox =
        document.getElementById("bOptions");

    const resultBox =
        document.getElementById("bResult");

    const nextButton =
        document.getElementById("bNextBtn");


    const total = bQuestions.length;

    const percentage =
        Math.round((bScore / total) * 100);


    questionBox.innerHTML = `
        <h2>🎉 Quiz Complete!</h2>

        <h3>${bTopic}</h3>
    `;


    optionsBox.innerHTML = `
        <div class="quiz-result">

            <h2>
                Score: ${bScore} / ${total}
            </h2>

            <p>
                Percentage: ${percentage}%
            </p>

            <button
                type="button"
                onclick="restartBQuiz()">

                🔄 Practice Again

            </button>

        </div>
    `;


    resultBox.innerHTML = "";

    nextButton.style.display = "none";
}


/* =========================
   RESTART
========================= */

function restartBQuiz() {

    bQuestionIndex = 0;

    bScore = 0;

    showBQuestion();
}
/* =========================
   C CERTIFICATE QUIZ
========================= */

let cQuestions = [];
let cQuestionIndex = 0;
let cScore = 0;
let cTopic = "";


/* =========================
   START C QUIZ
========================= */

function startCQuiz(topic) {

    if (typeof questionBank === "undefined") {
        alert("question.js load nahi hua!");
        return;
    }

    const topicMap = {
        "Leadership": "Leadership",
        "Communication": "Communication",
        "Disaster Management": "Disaster_Management",
        "Map Reading": "Map_Reading",
        "National Integration": "National_Integration",
        "Defence Awareness": "Defence_Awareness"
    };

    const actualTopic = topicMap[topic];

    if (
        !questionBank.C_Certificate ||
        !questionBank.C_Certificate[actualTopic]
    ) {
        alert("C Certificate ke questions nahi mile: " + topic);
        console.log(questionBank.C_Certificate);
        return;
    }

    cQuestions = questionBank.C_Certificate[actualTopic];

    cQuestionIndex = 0;
    cScore = 0;
    cTopic = topic;

    const area = document.getElementById("cQuizArea");

    if (!area) {
        alert("cQuizArea nahi mila!");
        return;
    }

    area.style.display = "block";

    document.getElementById("cQuizTitle").innerText =
        "📚 " + topic + " Practice";

    showCQuestion();

    area.scrollIntoView({
        behavior: "smooth"
    });
}


/* =========================
   SHOW C QUESTION
========================= */

function showCQuestion() {

    if (cQuestionIndex >= cQuestions.length) {
        showCResult();
        return;
    }

    const q = cQuestions[cQuestionIndex];

    document.getElementById("cQuestion").innerHTML = `
        <h3>
            Question ${cQuestionIndex + 1}
            / ${cQuestions.length}
        </h3>

        <p style="font-size:18px; font-weight:bold;">
            ${q.question}
        </p>
    `;

    document.getElementById("cOptions").innerHTML =
        q.options.map((option, index) => {

            return `
                <button
                    type="button"
                    class="b-option"
                    onclick="checkCAnswer(${index})">

                    ${String.fromCharCode(65 + index)}.
                    ${option}

                </button>
            `;

        }).join("");

    document.getElementById("cResult").innerHTML = "";

    document.getElementById("cNextBtn").style.display = "none";
}


/* =========================
   CHECK C ANSWER
========================= */

function checkCAnswer(selectedIndex) {

    const q = cQuestions[cQuestionIndex];

    const resultBox =
        document.getElementById("cResult");

    const buttons =
        document.querySelectorAll("#cOptions .b-option");

    // All options disable and highlight
    buttons.forEach((button, idx) => {
        button.disabled = true;
        if (idx === q.answer) {
            button.classList.add("correct-option");
        } else if (idx === selectedIndex) {
            button.classList.add("wrong-option");
        }
    });

    if (typeof incrementSolvedCount === "function") {
        incrementSolvedCount();
    }


    if (selectedIndex === q.answer) {

        cScore++;

        resultBox.innerHTML = `
            <div class="answer-box correct">

                <h3>✅ Correct Answer!</h3>

                <p>
                    ${q.explanation}
                </p>

            </div>
        `;

    } else {

        resultBox.innerHTML = `
            <div class="answer-box wrong">

                <h3>❌ Wrong Answer</h3>

                <p>
                    <b>Correct Answer:</b>
                    ${q.options[q.answer]}
                </p>

                <p>
                    ${q.explanation}
                </p>

            </div>
        `;
    }

    document.getElementById("cNextBtn").style.display =
        "block";
}


/* =========================
   NEXT C QUESTION
========================= */

function nextCQuestion() {

    cQuestionIndex++;

    showCQuestion();
}


/* =========================
   C RESULT
========================= */

function showCResult() {

    const total = cQuestions.length;

    const percentage =
        Math.round((cScore / total) * 100);

    document.getElementById("cQuestion").innerHTML = `
        <h2>🎉 Quiz Complete!</h2>

        <h3>${cTopic}</h3>
    `;

    document.getElementById("cOptions").innerHTML = `
        <div class="quiz-result">

            <h2>
                Score: ${cScore} / ${total}
            </h2>

            <p>
                Percentage: ${percentage}%
            </p>

            <button
                type="button"
                onclick="restartCQuiz()">

                🔄 Practice Again

            </button>

        </div>
    `;

    document.getElementById("cResult").innerHTML = "";

    document.getElementById("cNextBtn").style.display = "none";
}


/* =========================
   RESTART C QUIZ
========================= */

function restartCQuiz() {

    cQuestionIndex = 0;

    cScore = 0;

    showCQuestion();
}