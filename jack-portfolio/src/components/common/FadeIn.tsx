import React from 'react';
import { motion, type HTMLMotionProps, type Variants } from 'framer-motion';

interface FadeInProps extends HTMLMotionProps<any> {
  children: React.ReactNode;
  delay?: number;
  duration?: number;
  x?: number;
  y?: number;
  as?: string;
}

const FadeIn: React.FC<FadeInProps> = ({
  children,
  delay = 0,
  duration = 0.7,
  x = 0,
  y = 30,
  as = 'div', // Default to div
  ...rest
}) => {
  const Component = motion.create(as as any); // Uses motion.create() for dynamic element types

  const variants: Variants = {
    hidden: { opacity: 0, x, y },
    visible: { opacity: 1, x: 0, y: 0 },
  };

  return (
    <Component
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, margin: "50px", amount: 0 }} // Corrected amount to 0
      variants={variants}
      transition={{
        delay,
        duration,
        ease: [0.25, 0.1, 0.25, 1], // Custom bezier curve
      }}
      {...rest}
    >
      {children}
    </Component>
  );
};

export default FadeIn;