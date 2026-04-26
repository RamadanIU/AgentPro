# agent-pro-bridge

Локальный мост для запуска **stdio**-MCP-серверов из браузерного Agent Pro.

Браузер не может запускать локальные процессы (sandbox). Этот мост — крошечный Node-сервер
(~120 строк), который слушает `ws://127.0.0.1:7777`, по запросу из браузера спавнит
дочерний процесс (например, `npx @modelcontextprotocol/server-filesystem ...`)
и проксирует JSON-RPC между его `stdin/stdout` и WebSocket-сессией.

После этого Agent Pro работает с stdio-серверами **точно так же, как LM Studio или Claude Desktop**.

## Запуск

```bash
cd bridge
npm install
npm start
```

Откройте Agent Pro → Настройки → MCP-серверы. В заголовке секции должна загореться
зелёная точка «Локальный мост (stdio): подключён».

## Подключение stdio-сервера

В UI:
1. «Добавить сервер» → Транспорт = `stdio`.
2. Команда: `npx`, аргументы (по строке): `-y`, `@modelcontextprotocol/server-filesystem`, `/path/to/dir`.

Или импортируйте `mcp.json` (формат как у Claude Desktop / LM Studio):

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/projects"]
    },
    "git": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-git", "--repository", "/path/to/repo"]
    }
  }
}
```

## Удалённые MCP-серверы

Удалённые серверы (HTTP / SSE / WS) **не требуют моста** — Agent Pro подключается
к ним напрямую из браузера. Мост нужен только для `stdio`.

## Конфигурация

Переменные окружения:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `AGENT_PRO_BRIDGE_HOST` | `127.0.0.1` | Адрес для прослушивания. |
| `AGENT_PRO_BRIDGE_PORT` | `7777` | Порт. |

## Безопасность

⚠️ Мост спавнит произвольные процессы по запросу любой WebSocket-сессии. По умолчанию
он слушает только на `127.0.0.1`, так что доступ возможен только локально. **Не открывайте
этот порт наружу.**

## Протокол

WebSocket-фреймы — JSON-объекты:

| Направление | `type` | Поля | Описание |
|---|---|---|---|
| client → bridge | `spawn` | `config: { command, args, env, cwd }` | Запустить процесс. Только один раз на соединение. |
| bridge → client | `ready` | `pid` | Процесс запущен. |
| client → bridge | `rpc` | `payload` (любой JSON-RPC объект) | Отправить серверу через stdin. |
| bridge → client | `rpc` | `payload` | Сообщение от сервера (распарсенный stdout). |
| bridge → client | `stderr` | `text` | stderr процесса. |
| bridge → client | `exit` | `code`, `signal` | Процесс завершился. |
| bridge → client | `error` | `message` | Любая ошибка. |

## Лицензия

MIT.
