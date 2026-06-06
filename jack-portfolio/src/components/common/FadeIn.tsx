import React from 'react';
import { motion, type HTMLMotionProps, type Variants } from 'framer-motion';

interface FadeInProps extends HTMLMotionProps<any> {
  children: React.ReactNode;
  delay?: number;
  duration?: number;
  x?: number;
  y?: number;
  as?: keyof typeof motion; // Prop to specify the underlying HTML element/component
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
  const Component = motion[as as keyof typeof motion] as any; // Dynamically pick the motion component

  const variants: Variants = {
    hidden: { opacity: 0, x, y },
    visible: { opacity: 1, x: 0, y: 0 },
  };

  return (
    <Component
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, margin: "50px", amount: 0.2 }} // Increased amount to 0.2 for better visibility
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