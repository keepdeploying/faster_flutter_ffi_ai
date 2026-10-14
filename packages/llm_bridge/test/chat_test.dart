import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('formatChatMl', () {
    test('system + user, open assistant turn (the Qwen2.5 shape)', () {
      final text = formatChatMl(const [
        ChatMessage.system('You are a helpful assistant.'),
        ChatMessage.user('Name a colour.'),
      ]);
      expect(
        text,
        '<|im_start|>system\n'
        'You are a helpful assistant.<|im_end|>\n'
        '<|im_start|>user\n'
        'Name a colour.<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });

    test('multi-turn keeps order and closes finished turns', () {
      final text = formatChatMl(const [
        ChatMessage.user('Hi'),
        ChatMessage.assistant('Hello!'),
        ChatMessage.user('Bye'),
      ]);
      expect(
        text,
        '<|im_start|>user\nHi<|im_end|>\n'
        '<|im_start|>assistant\nHello!<|im_end|>\n'
        '<|im_start|>user\nBye<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });

    test('addAssistant: false leaves the conversation closed', () {
      final text = formatChatMl(const [
        ChatMessage.user('Hi'),
      ], addAssistant: false);
      expect(text, '<|im_start|>user\nHi<|im_end|>\n');
    });

    test('content is not escaped or trimmed', () {
      final text = formatChatMl(const [ChatMessage.user('  <b>é 🙂</b>\n')]);
      expect(text, contains('  <b>é 🙂</b>\n<|im_end|>'));
    });

    test('empty list with addAssistant is just the assistant header', () {
      expect(formatChatMl(const []), '<|im_start|>assistant\n');
    });
  });

  test('ChatMessage has value equality', () {
    expect(const ChatMessage.user('a'), const ChatMessage('user', 'a'));
    expect(const ChatMessage.user('a'), isNot(const ChatMessage.system('a')));
  });
}
