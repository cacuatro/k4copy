# K4 Signals — atualizações oficiais

Canal público de distribuição do K4 Signals para Windows, autorizado pelo proprietário.

Versão estável: **1.7.4**, cumulativa a partir da **1.3.4**.

O cliente consulta `updates/stable.json` após 15 segundos e a cada cinco minutos, enquanto o painel está aberto. A preferência pode ser desligada no rodapé. Instale o FIX 1.6.0 uma vez para habilitar o atualizador.

Cada pacote é assinado com RSA-3072/SHA-256 e possui verificação de tamanho e hashes. O aplicativo contém somente a chave pública. Não precisa de token GitHub na VPS. Os arquivos `.zip.b64` são ZIPs codificados em base64; não devem ser extraídos sem decodificar. A codificação permite a distribuição por arquivos de texto no GitHub.

O atualizador aguarda tarefas e configuração alterada sem salvar; solicita parada cooperativa, aguarda encerramento, guarda backup, aplica arquivos permitidos e verifica componentes. Reabre o painel e tenta retomar acompanhamento somente se já estava ativo. Existe pausa operacional durante atualização e reconexão. Falha de validação provoca rollback de código e bloqueio da mesma versão.

Não contém contas, credenciais, sessão Telegram, banco, logs ou chave privada de assinatura. Dados operacionais não são enviados a este repositório.

Os testes da versão inicial foram locais: 346 casos passaram. Aplicação nativa no Windows, reconexão com Telegram e execução na corretora precisam de validação no ambiente instalado. Nenhum resultado financeiro ou ausência de interrupção é garantido.

Para publicar versões futuras, use o kit privado de assinatura mantido separadamente. Nunca envie o kit/chave privada para este repositório. Publique pacotes com um novo número de versão e atualize o canal assinado por último, de preferência no mesmo commit. Pacotes existentes não devem ser substituídos. Consulte também as instruções e os relatórios dentro de cada FIX.

##1.7.0

Dan Golden: política local NOW com3 ordens XAUUSD e stop provisório10.00 unidades do preço, completadas por atualização de SL/TP sem duplicar entradas. Checkbox exclusivo Dan, risco e spread preservados. Edição com texto idêntico pode executar primeira entrada fresca sem claim prévio; histórico, mensagens expiradas e reenvios incertos continuam bloqueados. Diagnóstico de cotação inclui causa detalhada. Consulte README dentro do pacote para limites de5min e comportamento em falha parcial.

##1.7.1

Correção conservadora de feed com horário futuro: verifica avanço dos ticks antes de normalizar a diferença, preservando bloqueio de cotação congelada e o padrão UTC. Ajuste isolado por conta/terminal/ativo e registrado no diagnóstico. Não muda o relógio da VPS nem presume o fuso de arquivos históricos. Novas interpretações solicitadas em português brasileiro e apresentação de motivos conhecidos traduzida. Registros técnicos originais preservados. Consulte limites e relatórios no pacote.

## 1.7.2

Leitura conjunta das mensagens recentes e respostas, distinguindo listas de níveis de faixas. Níveis separados podem gerar pendentes SINGLE/MULTIPLE com SL/TP válidos, sem depender da política de faixa BLOCK. Complemento por resposta direta exige origem incompleta ao vivo em até cinco minutos. Pendentes existentes impedem duplicação no mesmo nível; a IA não fornece stop ausente nem reaproveita operação antiga. O stop de 10.00 do Dan continua exclusivo do NOW direto. Motivos em português. Validação local: 362 testes e sobreposição cumulativa desde 1.3.4; sem chamada real ao modelo ou envio à corretora nesta validação.

## 1.7.3

Dan: níveis individuais de pendentes sem SL passam a ter proteção provisória de 15.00 unidades do preço por entrada (BUY 4035 → SL 4020). Sem alvo, uma pendente por nível aguarda os parâmetros posteriores. SL/TP vinculados atualizam a mesma ordem ou posição, sem nova exposição; ampliar risco continua bloqueado. A proteção permanece após reinício. Checkbox exclusivo Dan e diagnóstico da política. Histórico, faixas, condições, falha da IA e ambiguidade não ativam o padrão. Risco e margem do conjunto são verificados antes da primeira ordem. Validação local: 383 testes com IA simulada e FakeMT5, sem envio real à corretora.

## 1.7.4

Amplia a política Dan de SL provisório 15.00 para instruções informais com preço, como Buying slowly, primeira entrada e listas we buying again, sempre com interpretação válida, LIMIT do lado correto e risco verificado. Repetir nível de operação ativa não cria exposição adicional. A recuperação distingue resultados respondidos a outra ideia informal. Regiões históricas incompletas aparecem com motivo de não execução; carregar histórico permanece somente contexto, e a recuperação de ordens antigas continua exigindo sinal completo e prova de preços intactos. Validação local: 393 testes, respostas da IA simuladas e FakeMT5; sem envio real à corretora.
