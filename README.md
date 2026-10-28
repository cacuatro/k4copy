# K4 Signals — atualizações oficiais

Canal público de distribuição do K4 Signals para Windows, autorizado pelo proprietário.

Versão estável inicial: **1.6.0**, cumulativa a partir da **1.3.4**.

O cliente consulta `updates/stable.json` após 15 segundos e a cada cinco minutos, enquanto o painel está aberto. A preferência pode ser desligada no rodapé. Instale o FIX 1.6.0 uma vez para habilitar o atualizador.

Cada pacote é assinado com RSA-3072/SHA-256 e possui verificação de tamanho e hashes. O aplicativo contém somente a chave pública. Não precisa de token GitHub na VPS. Os arquivos `.zip.b64` são ZIPs codificados em base64; não devem ser extraídos sem decodificar. A codificação permite a distribuição por arquivos de texto no GitHub.

O atualizador aguarda tarefas e configuração alterada sem salvar; solicita parada cooperativa, aguarda encerramento, guarda backup, aplica arquivos permitidos e verifica componentes. Reabre o painel e tenta retomar acompanhamento somente se já estava ativo. Existe pausa operacional durante atualização e reconexão. Falha de validação provoca rollback de código e bloqueio da mesma versão.

Não contém contas, credenciais, sessão Telegram, banco, logs ou chave privada de assinatura. Dados operacionais não são enviados a este repositório.

Os testes da versão inicial foram locais: 304 casos passaram. Aplicação nativa no Windows, reconexão com Telegram e execução na corretora precisam de validação no ambiente instalado. Nenhum resultado financeiro ou ausência de interrupção é garantido.

Para publicar versões futuras, use o kit privado de assinatura mantido separadamente. Nunca envie o kit/chave privada para este repositório. Publique pacotes com um novo número de versão e atualize o canal assinado por último, de preferência no mesmo commit. Pacotes existentes não devem ser substituídos. Consulte também as instruções e os relatórios dentro de cada FIX.
