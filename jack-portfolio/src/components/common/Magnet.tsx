import { useRef, useState, useEffect, useCallback, useMemo } from 'react';
import { motion, useSpring, useTransform, type MotionValue } from 'framer-motion';

interface MagnetProps {
  children: React.ReactNode;
  padding?: number;
  strength?: number;
  activeTransition?: string;
  inactiveTransition?: string;
  className?: string; // Allow passing Tailwind classes
}

const Magnet: React.FC<MagnetProps> = ({
  children,
  padding = 20,
  strength = 3,
  activeTransition = 'transform 0.3s ease-out',
  inactiveTransition = 'transform 0.6s ease-in-out',
  className = '',
}) => {
  const ref = useRef<HTMLDivElement>(null);
  const [isHovered, setIsHovered] = useState(false);
  const [mousePosition, setMousePosition] = useState({ x: 0, y: 0 });

  // Motion values for spring animations
  const springX = useSpring(0, { stiffness: 150, damping: 10 });
  const springY = useSpring(0, { stiffness: 150, damping: 10 });

  // Use useTransform to apply the magnetic effect when hovered
  const xTransform: MotionValue<number> = useTransform(springX, () => {
    if (isHovered) {
      if (ref.current) {
        const { left, width } = ref.current.getBoundingClientRect();
        const centerX = left + width / 2;
        return (mousePosition.x - centerX) / strength;
      }
    }
    return 0;
  });

  const yTransform: MotionValue<number> = useTransform(springY, () => {
    if (isHovered) {
      if (ref.current) {
        const { top, height } = ref.current.getBoundingClientRect();
        const centerY = top + height / 2;
        return (mousePosition.y - centerY) / strength;
      }
    }
    return 0;
  });

  // Update spring values more directly when mouse position changes
  useEffect(() => {
    if (isHovered) {
      springX.set(mousePosition.x);
      springY.set(mousePosition.y);
    } else {
      // Reset the spring to 0 when not hovered
      springX.set(0);
      springY.set(0);
    }
  }, [isHovered, mousePosition, springX, springY]);

  const handleMouseMove = useCallback((e: MouseEvent) => {
    if (ref.current) {
      const { left, top, width, height } = ref.current.getBoundingClientRect();
      const clientX = e.clientX;
      const clientY = e.clientY;

      // Check if mouse is within the padding area around the element
      const isInPaddedArea =
        clientX >= left - padding &&
        clientX <= left + width + padding &&
        clientY >= top - padding &&
        clientY <= top + height + padding;

      setIsHovered(isInPaddedArea);
      setMousePosition({ x: clientX, y: clientY });
    }
  }, [padding]);

  useEffect(() => {
    window.addEventListener('mousemove', handleMouseMove, { passive: true });

    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
    };
  }, [handleMouseMove]);

  const style = useMemo(() => ({
    willChange: 'transform',
    transition: isHovered ? activeTransition : inactiveTransition,
    x: xTransform,
    y: yTransform,
  }), [isHovered, activeTransition, inactiveTransition, xTransform, yTransform]);

  return (
    <motion.div
      ref={ref}
      style={style}
      className={className}
      onMouseLeave={() => setIsHovered(false)} // Ensure reset on actual leave
    >
      {children}
    </motion.div>
  );
};

export default Magnet;