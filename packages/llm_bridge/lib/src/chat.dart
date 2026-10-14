// Chat messages and a plain-Dart ChatML formatter.
//
// The real formatting is done by llama.cpp itself, from the template stored in
// the model file (see LlamaBackend.formatChat). This fallback exists for models
// whose template llama.cpp does not recognise: ChatML is what llama.cpp
// itself falls back to, and what Qwen, SmolLM and many others use.

/// One message of a conversation.
class ChatMessage {
  const ChatMessage(this.role, this.content);
  const ChatMessage.system(this.content) : role = 'system';
  const ChatMessage.user(this.content) : role = 'user';
  const ChatMessage.assistant(this.content) : role = 'assistant';

  final String role;
  final String content;

  @override
  String toString() => '$role: $content';

  @override
  bool operator ==(Object other) =>
      other is ChatMessage && other.role == role && other.content == content;

  @override
  int get hashCode => Object.hash(role, content);
}

/// Formats [messages] as ChatML:
///
/// ```text
/// <|im_start|>system
/// You are helpful.<|im_end|>
/// <|im_start|>user
/// Hi<|im_end|>
/// <|im_start|>assistant
/// ```
///
/// With [addAssistant] the text ends with the open assistant turn, which is
/// where generation starts.
String formatChatMl(List<ChatMessage> messages, {bool addAssistant = true}) {
  final out = StringBuffer();
  for (final m in messages) {
    out
      ..write('<|im_start|>')
      ..write(m.role)
      ..write('\n')
      ..write(m.content)
      ..write('<|im_end|>\n');
  }
  if (addAssistant) out.write('<|im_start|>assistant\n');
  return out.toString();
}
