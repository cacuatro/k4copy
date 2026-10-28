# K4Telegram2MT5 0.4.28

Correção cumulativa sobre 0.4.25. Não instala dependências e não altera config.yaml,
.env, sessões, bancos, contas ou lotes. SL e TPs do sinal permanecem os mesmos.

IA: aceita um objeto JSON, bloco Markdown JSON ou repetição idêntica do objeto.
Conteúdo adicional não JSON, campos duplicados e objetos conflitantes continuam
bloqueados. Há uma única nova tentativa em timeout, erro de formato, conexão,
HTTP 429 ou HTTP 5xx. Falha persistente não libera entrada sem interpretação.
O timeout configurado vale por tentativa; com 6 segundos são até aproximadamente
12 segundos de espera de rede, além de processamento. Validade do sinal continua
sendo verificada pelas regras locais.

Entradas exatas de GOLD/XAUUSD: tolerância padrão de 0.75 unidades do preço,
limitada a 25% da distância da entrada até TP1 no sentido desfavorável. Usa ASK
para BUY e BID para SELL; exige SL válido, limite de distância do SL, spread
permitido e preço anterior ao TP1. Revalida a cotação antes de cada ordem.
Não garante preço de preenchimento, que depende da corretora e do desvio já
configurado. Não amplia o deviation_points. Não modifica o comportamento NOW.
Se já existem ordens registradas, não converte pendentes por essa tolerância.
Fora da tolerância, continua usando ordens pendentes no preço original.

Configuração opcional em config.yaml, seção execution (não duplicar a seção):

```yaml
execution:
  exact_entry_tolerance_price: 0.75
  exact_entry_max_tp_progress: 0.25
```

Use exact_entry_tolerance_price: 0 para retornar ao comportamento anterior.
As opções são preservadas ao salvar pelo painel; esta versão as configura pelo YAML.

Atualizações automáticas: o painel consulta o canal assinado
telegram-updates/stable.json em cacuatro/k4copy após 15 segundos e a cada cinco
minutos. Ao encontrar nova versão, verifica assinatura e hashes, encerra
internamente o acompanhamento, aplica a atualização, reabre o painel e retoma
somente se o robô estava ativo. Não pede confirmação de parada nem nova liberação
LIVE nessa retomada. Se estava parado, continua parado; mantém LIVE/DRY RUN.
O mesmo fluxo funciona ao abrir por start_gui.bat ou pelo módulo rafa_copier.gui.

O reinício não envia comandos de fechamento, não altera SL/TP e não apaga bancos,
sessões ou configurações. Ao conectar, reconcilia tickets/SL/TP com o MT5 antes de
iniciar o consumo de mensagens. Posições e pendentes existentes continuam sendo
acompanhadas, inclusive pendentes ativadas durante o reinício. A corretora pode
executar SL/TP durante a pausa: o estado encontrado no MT5 prevalece sobre o estado
anterior. Não há garantia de acompanhamento sem interrupção: há uma pausa breve
para atualização/reconexão e mensagens nesse intervalo dependem do Telegram.

O atualizador aguarda edições não salvas e tarefas auxiliares. Se a configuração
salva mudou desde que o robô iniciou, adia a atualização até o estado ficar
consistente. Usa encerramento interno e trava de processos, sem confirmação do
usuário e sem forçar o encerramento pelo atualizador. Uma instância que não
encerre bloqueia a troca de arquivos. Backup e rollback protegem o código; se o
rollback não puder terminar, o reinício fica bloqueado. Na falha com rollback
concluído, tenta reabrir a versão anterior e retomar o mesmo modo. A retomada usa
uma autorização local de uso único, válida por três minutos e vinculada ao hash
da configuração; uma instalação inicial nunca liga operações sozinha.

Canal publicado separadamente do K4 Signals. Não use
updates/stable.json: ele pertence ao K4 Signals.

Instalação inicial: encerre robô e painel, extraia o FIX, execute APLICAR_FIX.bat
e selecione a pasta atual que contém rafa_copier e config.yaml. Abra depois por
start_gui.bat. Mantenha a instalação existente; não copie seus dados ao GitHub.

Validação automatizada local com MT5 simulado. Aplicação nativa do atualizador,
conexão Telegram e execução real no Windows ainda precisam de validação na VPS.

Na versão 0.4.28, a faixa abaixo do título mostra o estado da atualização e a hora da última verificação. O botão Verificar agora antecipa a consulta, sem duplicar requisições. Falhas de rede, versão bloqueada e espera por alterações não salvas aparecem nessa faixa.
