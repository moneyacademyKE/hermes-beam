import React from 'react';
import { motion } from 'framer-motion';

interface LiveProjectButtonProps {
  className?: string;
  onClick?: () => void;
  label?: string;
}

const LiveProjectButton: React.FC<LiveProjectButtonProps> = ({
  className,
  onClick,
  label = 'Live Project',
}) => {
  return (
    <motion.button
      className={`
        rounded-full border-2 border-light-text text-light-text
        px-8 py-3 sm:px-10 sm:py-3.5
        text-sm sm:text-base font-medium uppercase tracking-widest
        transition-colors duration-300
        hover:bg-light-text/10
        ${className}
      `}
      onClick={onClick}
      whileHover={{ scale: 1.05 }}
      whileTap={{ scale: 0.95 }}
      transition={{ type: "spring", stiffness: 400, damping: 17 }}
    >
      {label}
    </motion.button>
  );
};

export default LiveProjectButton;