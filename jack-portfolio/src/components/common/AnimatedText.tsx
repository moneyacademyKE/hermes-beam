import { useRef } from 'react';
import { motion, useScroll, useTransform } from 'framer-motion';

interface AnimatedTextProps {
  text: string;
  className?: string;
  style?: React.CSSProperties;
}

const AnimatedText: React.FC<AnimatedTextProps> = ({ text, className, style }) => {
  const ref = useRef<HTMLParagraphElement>(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ['start 0.8', 'end 0.2'], // Adjust for desired scroll effect
  });

  const words = text.split(' ');

  return (
    <p ref={ref} className={`relative flex flex-wrap justify-center ${className}`} style={style}>
      {words.map((word, wordIndex) => (
        <span key={wordIndex} className="block relative whitespace-pre-wrap"> {/* Use whitespace-pre-wrap to preserve spaces */}
          {word.split('').map((char, charIndex) => {
            const start = (wordIndex * text.length + charIndex) / (text.length * 1.5); // Stagger based on total character index
            const end = start + 0.5;

            const opacity = useTransform(scrollYProgress, [start, end], [0.2, 1]);

            return (
              <span
                key={`${wordIndex}-${charIndex}`}
                className="relative inline-block" // Ensure spacing is consistent around letters
              >
                {/* Invisible placeholder for layout and spacing */}
                <span className="opacity-0 select-none pointer-events-none">{char}</span>
                {/* Absolute positioned animated span */}
                <motion.span style={{ opacity }} className="absolute inset-0 inline-block text-center">
                  {char}
                </motion.span>
              </span>
            );
          })}
          {/* Add a space after each word, unless it's the last word */}
          {wordIndex < words.length - 1 && <span className="inline-block">&nbsp;</span>}
        </span>
      ))}
    </p>
  );
};

export default AnimatedText;