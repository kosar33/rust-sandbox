# 1. Системные пакеты
echo "=== 1. Установка системных зависимостей ==="
pkg update && pkg upgrade -y
pkg install nodejs rust build-essential curl -y

# 2. Выбор папки (создаст уникальное имя, например rust-sandbox-1)
echo "=== 2. Создание рабочей директории ==="
DIR="rust-sandbox"
COUNTER=1
while [ -d "$DIR" ]; do
    DIR="rust-sandbox-$COUNTER"
    COUNTER=$((COUNTER+1))
done
mkdir "$DIR" && cd "$DIR"
echo "Создана папка: $DIR"

# 3. Файлы Node.js
cat << 'EOF' > package.json
{
  "name": "rust-sandbox",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "ws": "^8.16.0"
  },
  "scripts": {
    "start": "node server.js"
  }
}
EOF

cat << 'EOF' > server.js
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const WORKSPACE_DIR = path.join(__dirname, 'rust-workspace');
const PROJECTS_FILE = path.join(__dirname, 'projects.json');

if (!fs.existsSync(WORKSPACE_DIR)) {
    fs.mkdirSync(WORKSPACE_DIR, { recursive: true });
    fs.mkdirSync(path.join(WORKSPACE_DIR, 'src'), { recursive: true });
    
    const cargoToml = `[package]
name = "web_app"
version = "0.1.0"
edition = "2024"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
`;
    fs.writeFileSync(path.join(WORKSPACE_DIR, 'Cargo.toml'), cargoToml);
}

function getProjects() {
    if (!fs.existsSync(PROJECTS_FILE)) return {};
    try {
        return JSON.parse(fs.readFileSync(PROJECTS_FILE, 'utf8'));
    } catch (e) {
        return {};
    }
}

function saveProjects(projects) {
    fs.writeFileSync(PROJECTS_FILE, JSON.stringify(projects, null, 2), 'utf8');
}

let activeProcess = null;
let wsClient = null;

wss.on('connection', (ws) => {
    wsClient = ws;
    ws.send(JSON.stringify({ type: 'info', data: 'Подключено к Termux-компилятору\n' }));
    ws.on('close', () => {
        wsClient = null;
        if (activeProcess) {
            activeProcess.kill();
            activeProcess = null;
        }
    });
});

function logToClient(type, data) {
    if (wsClient && wsClient.readyState === WebSocket.OPEN) {
        wsClient.send(JSON.stringify({ type, data }));
    }
}

app.post('/api/run', (req, res) => {
    const { main_rs, cargo_toml } = req.body;
    if (!main_rs || !cargo_toml) {
        return res.status(400).json({ error: 'Не все файлы предоставлены' });
    }

    fs.writeFileSync(path.join(WORKSPACE_DIR, 'src', 'main.rs'), main_rs);
    fs.writeFileSync(path.join(WORKSPACE_DIR, 'Cargo.toml'), cargo_toml);

    if (activeProcess) {
        activeProcess.kill();
        logToClient('info', 'Предыдущий бэкенд остановлен.\n');
    }

    logToClient('info', 'Запуск компиляции (cargo run)...\n');
    activeProcess = spawn('cargo', ['run'], { cwd: WORKSPACE_DIR });

    activeProcess.stdout.on('data', (data) => logToClient('stdout', data.toString()));
    activeProcess.stderr.on('data', (data) => logToClient('stderr', data.toString()));

    activeProcess.on('close', (code) => {
        logToClient('info', `Процесс завершился с кодом: ${code}\n`);
        activeProcess = null;
    });

    res.json({ status: 'started' });
});

app.post('/api/stop', (req, res) => {
    if (activeProcess) {
        activeProcess.kill();
        activeProcess = null;
        logToClient('info', 'Процесс принудительно остановлен.\n');
        return res.json({ status: 'stopped' });
    }
    res.json({ status: 'not_running' });
});

app.get('/api/projects', (req, res) => {
    res.json(getProjects());
});

app.post('/api/projects', (req, res) => {
    const { name, main_rs, cargo_toml } = req.body;
    if (!name || !main_rs || !cargo_toml) {
        return res.status(400).json({ error: 'Не заполнены все поля проекта' });
    }
    const projects = getProjects();
    projects[name] = { main_rs, cargo_toml, saved_at: new Date() };
    saveProjects(projects);
    res.json({ status: 'saved', projects });
});

app.delete('/api/projects/:name', (req, res) => {
    const name = req.params.name;
    const projects = getProjects();
    if (projects[name]) {
        delete projects[name];
        saveProjects(projects);
        return res.json({ status: 'deleted', projects });
    }
    res.status(404).json({ error: 'Проект не найден' });
});

server.listen(3000, '0.0.0.0', () => {
    console.log(`Сервер управления запущен на http://localhost:3000`);
});
EOF

# 4. Скачивание зависимостей стилей и подсветки в public/ (для полной оффлайн работы)
echo "=== 4. Офлайн-сохранение библиотек (Tailwind & Prism) ==="
mkdir -p public
curl -sSL -o public/tailwind.js https://cdn.tailwindcss.com
curl -sSL -o public/prism.js https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/prism.min.js
curl -sSL -o public/prism-rust.js https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-rust.min.js
curl -sSL -o public/prism-toml.js https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-toml.min.js
curl -sSL -o public/prism.css https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/themes/prism-tomorrow.min.css

# 5. Создаем public/index.html
cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Rust Sandbox</title>
    <script src="/tailwind.js"></script>
    <link href="/prism.css" rel="stylesheet">
    <script src="/prism.js"></script>
    <script src="/prism-rust.js"></script>
    <script src="/prism-toml.js"></script>
    <style>
        .editor-area, .editor-pre {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
            font-size: 11px !important;
            line-height: 1.5 !important;
            padding: 12px !important;
            margin: 0 !important;
            border: none !important;
            white-space: pre !important;
            word-wrap: normal !important;
        }
    </style>
</head>
<body class="bg-gray-900 text-gray-100 h-dvh md:h-screen flex flex-col font-sans overflow-hidden">

    <header class="bg-gray-800 p-3 border-b border-gray-700 flex flex-col gap-2 shrink-0">
        <div class="flex justify-between items-center">
            <h1 class="text-base font-bold text-orange-500">🦀 Rust Sandbox</h1>
            <div class="flex gap-2">
                <button id="runBtn" class="bg-green-600 active:bg-green-700 text-white font-bold py-1 px-3 rounded text-xs">Старт</button>
                <button id="stopBtn" class="bg-red-600 active:bg-red-700 text-white font-bold py-1 px-3 rounded text-xs">Стоп</button>
            </div>
        </div>
        
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 bg-gray-950 p-2 rounded border border-gray-700 text-xs">
            <div class="flex gap-1.5">
                <select id="projectSelect" class="flex-1 bg-gray-800 text-white p-1.5 rounded outline-none border border-gray-600 min-w-0">
                    <option value="">-- Выберите закладку --</option>
                </select>
                <button id="deleteBtn" class="bg-gray-700 hover:bg-red-700 text-xs px-3 py-1.5 rounded text-red-400 font-bold shrink-0">Удалить</button>
            </div>
            <div class="flex gap-1.5">
                <input id="saveNameInput" type="text" placeholder="Имя для сохранения" class="flex-1 bg-gray-800 text-white p-1.5 rounded text-xs outline-none border border-gray-600 min-w-0">
                <button id="saveBtn" class="bg-orange-600 active:bg-orange-700 text-white text-xs font-bold py-1.5 px-3 rounded shrink-0">Сохранить</button>
            </div>
        </div>
    </header>

    <div class="flex border-b border-gray-700 bg-gray-800 text-[11px] shrink-0">
        <button id="tabMain" class="flex-1 py-1.5 text-center border-b-2 border-orange-500 font-semibold text-orange-400">main.rs</button>
        <button id="tabCargo" class="flex-1 py-1.5 text-center border-b-2 border-transparent font-semibold text-gray-400 hover:text-gray-200">Cargo.toml</button>
        <button id="tabImport" class="flex-1 py-1.5 text-center border-b-2 border-transparent font-semibold text-gray-400 hover:text-gray-200 bg-gray-850">📥 Импорт от ИИ</button>
    </div>

    <main class="flex-1 flex flex-col md:flex-row overflow-hidden">
        <div class="flex-1 flex flex-col border-b md:border-b-0 md:border-r border-gray-700 relative overflow-hidden">
            
            <div id="containerMain" class="flex-1 relative overflow-hidden">
                <pre id="preMain" class="editor-pre absolute inset-0 bg-gray-950 text-yellow-100 pointer-events-none overflow-auto"><code id="codeMain" class="language-rust"></code></pre>
                <textarea id="areaMain" class="editor-area absolute inset-0 bg-transparent text-transparent caret-white outline-none resize-none overflow-auto" spellcheck="false" placeholder="Код main.rs"></textarea>
            </div>

            <div id="containerCargo" class="hidden flex-1 relative overflow-hidden">
                <pre id="preCargo" class="editor-pre absolute inset-0 bg-gray-950 text-yellow-100 pointer-events-none overflow-auto"><code id="codeCargo" class="language-toml"></code></pre>
                <textarea id="areaCargo" class="editor-area absolute inset-0 bg-transparent text-transparent caret-white outline-none resize-none overflow-auto" spellcheck="false" placeholder="Конфигурация Cargo.toml"></textarea>
            </div>
            
            <div id="areaImportBlock" class="hidden flex-1 flex flex-col bg-gray-900 p-3 gap-2 overflow-hidden">
                <div class="flex justify-between items-center shrink-0 gap-2">
                    <p class="text-[10px] text-gray-400 leading-tight">Вставьте ответ нейросети (с разделителями === Cargo.toml === и === main.rs ===):</p>
                    <button id="copyPromptBtn" class="bg-gray-700 hover:bg-gray-600 active:bg-gray-500 text-white font-semibold py-1 px-2.5 rounded text-[10px] shrink-0 flex items-center gap-1 transition">
                        📋 Копировать промпт
                    </button>
                </div>
                <textarea id="importTextArea" class="flex-1 p-2 bg-gray-950 font-mono text-[11px] text-green-300 outline-none resize-none rounded border border-gray-700" placeholder="=== Cargo.toml ===&#10;...&#10;=== main.rs ===&#10;..."></textarea>
                <button id="confirmImportBtn" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-1.5 rounded text-xs shrink-0">Импортировать в редакторы</button>
            </div>
        </div>

        <div class="h-2/5 md:h-full md:w-1/2 flex flex-col bg-black shrink-0 overflow-hidden border-t border-gray-700 md:border-t-0">
            <div class="bg-gray-800 px-3 py-1 text-[10px] text-gray-400 border-b border-gray-700 flex justify-between items-center shrink-0">
                <span>Терминал сборки</span>
                <button id="clearBtn" class="text-gray-500 active:text-gray-300">Очистить</button>
            </div>
            <pre id="terminal" class="flex-1 p-3 font-mono text-[10px] overflow-y-auto text-green-400 whitespace-pre-wrap select-text"></pre>
        </div>
    </main>

    <script>
        const tabMain = document.getElementById('tabMain');
        const tabCargo = document.getElementById('tabCargo');
        const tabImport = document.getElementById('tabImport');

        const containerMain = document.getElementById('containerMain');
        const containerCargo = document.getElementById('containerCargo');
        const areaImportBlock = document.getElementById('areaImportBlock');

        const areaMain = document.getElementById('areaMain');
        const areaCargo = document.getElementById('areaCargo');
        const importTextArea = document.getElementById('importTextArea');
        const confirmImportBtn = document.getElementById('confirmImportBtn');
        const copyPromptBtn = document.getElementById('copyPromptBtn');

        const codeMain = document.getElementById('codeMain');
        const preMain = document.getElementById('preMain');
        const codeCargo = document.getElementById('codeCargo');
        const preCargo = document.getElementById('preCargo');

        const projectSelect = document.getElementById('projectSelect');
        const saveNameInput = document.getElementById('saveNameInput');
        const saveBtn = document.getElementById('saveBtn');
        const deleteBtn = document.getElementById('deleteBtn');

        const terminal = document.getElementById('terminal');

        let loadedProjects = {};

        function syncHighlight(textarea, codeElem, preElem) {
            let text = textarea.value;
            if (text[text.length - 1] === "\n") {
                text += " ";
            }
            codeElem.textContent = text;
            Prism.highlightElement(codeElem);
        }

        function setupEditorSync(textarea, codeElem, preElem) {
            textarea.addEventListener('input', () => syncHighlight(textarea, codeElem, preElem));
            textarea.addEventListener('scroll', () => {
                preElem.scrollTop = textarea.scrollTop;
                preElem.scrollLeft = textarea.scrollLeft;
            });
        }

        setupEditorSync(areaMain, codeMain, preMain);
        setupEditorSync(areaCargo, codeCargo, preCargo);

        const aiPromptTemplate = `Напиши веб-приложение на Rust с использованием фреймворка Axum, которое делает [ОПИШИТЕ ВАШУ ЗАДАЧУ]. 
Выдай весь проект СТРОГО в одном текстовом блоке с разделителями, как в шаблоне ниже, без лишних разговоров и пояснений вне кода:

=== Cargo.toml ===
[package]
name = "web_app"
version = "0.1.0"
edition = "2024"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }

=== main.rs ===
use axum::{routing::get, Router};
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(|| async { "Привет! Бэкенд на Rust запущен!" }));
    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    println!("Сервер работает на http://localhost:8080");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}`;

        copyPromptBtn.addEventListener('click', () => {
            navigator.clipboard.writeText(aiPromptTemplate).then(() => {
                const originalText = copyPromptBtn.textContent;
                copyPromptBtn.textContent = '✅ Скопировано!';
                copyPromptBtn.classList.remove('bg-gray-700');
                copyPromptBtn.classList.add('bg-green-700');
                setTimeout(() => {
                    copyPromptBtn.textContent = originalText;
                    copyPromptBtn.classList.remove('bg-green-700');
                    copyPromptBtn.classList.add('bg-gray-700');
                }, 1500);
            }).catch(err => {
                alert('Ошибка копирования: ' + err);
            });
        });

        function switchTab(activeTab, activeArea) {
            [tabMain, tabCargo, tabImport].forEach(t => {
                t.classList.remove('border-orange-500', 'text-orange-400');
                t.classList.add('border-transparent', 'text-gray-400');
            });
            [containerMain, containerCargo, areaImportBlock].forEach(a => a.classList.add('hidden'));

            activeTab.classList.remove('border-transparent', 'text-gray-400');
            activeTab.classList.add('border-orange-500', 'text-orange-400');
            activeArea.classList.remove('hidden');
        }

        tabMain.addEventListener('click', () => switchTab(tabMain, containerMain));
        tabCargo.addEventListener('click', () => switchTab(tabCargo, containerCargo));
        tabImport.addEventListener('click', () => switchTab(tabImport, areaImportBlock));

        function parseUnifiedFormat(text) {
            const cargoStart = text.indexOf('=== Cargo.toml ===');
            const mainStart = text.indexOf('=== main.rs ===');
            
            let cargoContent = '';
            let mainContent = '';
            
            if (cargoStart !== -1 && mainStart !== -1) {
                if (cargoStart < mainStart) {
                    cargoContent = text.substring(cargoStart + '=== Cargo.toml ==='.length, mainStart).trim();
                    mainContent = text.substring(mainStart + '=== main.rs ==='.length).trim();
                } else {
                    mainContent = text.substring(mainStart + '=== main.rs ==='.length, cargoStart).trim();
                    cargoContent = text.substring(cargoStart + '=== Cargo.toml ==='.length).trim();
                }
            } else {
                mainContent = text.trim();
                cargoContent = `[package]\nname = "web_app"\nversion = "0.1.0"\nedition = "2024"\n\n[dependencies]\naxum = "0.7"\ntokio = { version = "1", features = ["full"] }\n`;
            }
            
            return { cargoContent, mainContent };
        }

        confirmImportBtn.addEventListener('click', () => {
            const rawText = importTextArea.value.trim();
            if (!rawText) return alert('Поле импорта пусто!');

            const { cargoContent, mainContent } = parseUnifiedFormat(rawText);
            areaMain.value = mainContent;
            areaCargo.value = cargoContent;

            syncHighlight(areaMain, codeMain, preMain);
            syncHighlight(areaCargo, codeCargo, preCargo);

            appendLog('Импорт успешно завершен! Файлы разложены по вкладкам.\n', 'info');
            importTextArea.value = '';
            switchTab(tabMain, containerMain);
        });

        async function loadProjectsList() {
            const res = await fetch('/api/projects');
            loadedProjects = await res.json();
            
            projectSelect.innerHTML = '<option value="">-- Выберите закладку --</option>';
            Object.keys(loadedProjects).forEach(name => {
                const opt = document.createElement('option');
                opt.value = name;
                opt.textContent = name;
                projectSelect.appendChild(opt);
            });
        }

        projectSelect.addEventListener('change', () => {
            const name = projectSelect.value;
            if (name && loadedProjects[name]) {
                areaMain.value = loadedProjects[name].main_rs;
                areaCargo.value = loadedProjects[name].cargo_toml;
                saveNameInput.value = name;

                syncHighlight(areaMain, codeMain, preMain);
                syncHighlight(areaCargo, codeCargo, preCargo);

                appendLog(`Загружена закладка: "${name}"\n`, 'info');
            }
        });

        saveBtn.addEventListener('click', async () => {
            const name = saveNameInput.value.trim();
            if (!name) return alert('Укажите имя для сохранения!');

            const res = await fetch('/api/projects', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, main_rs: areaMain.value, cargo_toml: areaCargo.value })
            });
            if (res.ok) {
                appendLog(`Закладка "${name}" успешно сохранена.\n`, 'info');
                await loadProjectsList();
                projectSelect.value = name;
            }
        });

        deleteBtn.addEventListener('click', async () => {
            const name = projectSelect.value;
            if (!name) return alert('Выберите закладку для удаления');
            
            if (confirm(`Удалить закладку "${name}"?`)) {
                const res = await fetch(`/api/projects/${encodeURIComponent(name)}`, { method: 'DELETE' });
                if (res.ok) {
                    appendLog(`Закладка "${name}" удалена.\n`, 'info');
                    saveNameInput.value = '';
                    await loadProjectsList();
                }
            }
        });

        const socket = new WebSocket(`ws://${window.location.host}`);
        socket.onmessage = (event) => {
            const msg = JSON.parse(event.data);
            appendLog(msg.data, msg.type);
        };

        function appendLog(text, type) {
            const span = document.createElement('span');
            span.className = type === 'stderr' ? 'text-red-400' : (type === 'info' ? 'text-blue-400' : 'text-green-400');
            span.textContent = text;
            terminal.appendChild(span);
            terminal.scrollTop = terminal.scrollHeight;
        }

        document.getElementById('runBtn').addEventListener('click', async () => {
            terminal.textContent = '';
            appendLog('Запуск...\n', 'info');
            try {
                await fetch('/api/run', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ main_rs: areaMain.value, cargo_toml: areaCargo.value })
                });
            } catch (err) {
                appendLog(`Ошибка отправки: ${err.message}\n`, 'stderr');
            }
        });

        document.getElementById('stopBtn').addEventListener('click', () => fetch('/api/stop', { method: 'POST' }));
        document.getElementById('clearBtn').addEventListener('click', () => terminal.textContent = '');

        const defaultCode = `use axum::{routing::get, Router};
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(|| async { "Привет! Этот бэкенд на Rust запущен прямо из браузера на телефоне!" }));
    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    println!("Сервер работает на http://localhost:8080");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}`;

        const defaultCargo = `[package]
name = "web_app"
version = "0.1.0"
edition = "2024"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
`;

        areaMain.value = defaultCode;
        areaCargo.value = defaultCargo;

        syncHighlight(areaMain, codeMain, preMain);
        syncHighlight(areaCargo, codeCargo, preCargo);

        loadProjectsList();
    </script>
</body>
</html>
EOF

# 6. Установка npm пакетов
echo "=== 6. Установка NPM зависимостей ==="
npm install

# 7. Пре-компиляция Rust зависимостей (crates), чтобы они скачались во время установки
echo "=== 7. Предварительное скачивание и компиляция зависимостей Rust ==="
mkdir -p rust-workspace/src

cat << 'EOF' > rust-workspace/Cargo.toml
[package]
name = "web_app"
version = "0.1.0"
edition = "2024"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
EOF

cat << 'EOF' > rust-workspace/src/main.rs
use axum::{routing::get, Router};
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(|| async { "Hello!" }));
    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
EOF

cd rust-workspace

# Запускаем сборку Rust с автоматическим обходом ошибки ETXTBSY (Text file busy) на Android
echo "Запуск сборки Rust..."
if ! cargo build; then
    echo "Диск занят системой Android (os error 26). Автоматический повтор в 1 поток через 2 секунды..."
    sleep 2
    if ! cargo build -j 1; then
        echo "Повторный сбой. Пробуем финальный перезапуск компилятора через 2 секунды..."
        sleep 2
        cargo build -j 1
    fi
fi

cd ..

echo ""
echo "=== СБОРКА И НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНЫ! ==="
echo "Проект развернут в папке: $DIR"
echo "Для запуска введите следующие команды в Termux:"
echo "  cd $DIR"
echo "  node server.js"
echo ""
echo "После этого откройте браузер на http://localhost:3000"
