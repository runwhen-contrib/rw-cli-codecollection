# Memory Optimization Implementation Guide

## Quick Wins (Implement First)

### 1. Virtual Scrolling for Chat Messages

Install required dependencies:
```bash
npm install react-window react-window-infinite-loader
```

**ChatMessageList.jsx:**
```jsx
import React, { useState, useCallback } from 'react';
import { FixedSizeList as List } from 'react-window';
import InfiniteLoader from 'react-window-infinite-loader';

const ChatMessageList = ({ workspaceId }) => {
  const [messages, setMessages] = useState([]);
  const [hasNextPage, setHasNextPage] = useState(true);
  const [isNextPageLoading, setIsNextPageLoading] = useState(false);
  const [page, setPage] = useState(1);

  const loadMoreItems = useCallback(async (startIndex, stopIndex) => {
    if (isNextPageLoading) return;
    
    setIsNextPageLoading(true);
    try {
      const response = await fetch(
        `/api/workspace/${workspaceId}/chat/messages?page=${page}&limit=50`
      );
      const newMessages = await response.json();
      
      setMessages(prev => [...prev, ...newMessages]);
      setHasNextPage(newMessages.length === 50);
      setPage(prev => prev + 1);
    } catch (error) {
      console.error('Failed to load messages:', error);
    } finally {
      setIsNextPageLoading(false);
    }
  }, [workspaceId, page, isNextPageLoading]);

  const isItemLoaded = useCallback(index => {
    return !hasNextPage || index < messages.length;
  }, [hasNextPage, messages.length]);

  const MessageRow = ({ index, style }) => {
    if (!isItemLoaded(index)) {
      return (
        <div style={style} className="message-loading">
          Loading...
        </div>
      );
    }

    const message = messages[index];
    return (
      <div style={style} className="message-item">
        <div className="message-header">
          <span className="author">{message.author}</span>
          <span className="timestamp">{message.timestamp}</span>
        </div>
        <div className="message-content">{message.content}</div>
      </div>
    );
  };

  return (
    <InfiniteLoader
      isItemLoaded={isItemLoaded}
      itemCount={hasNextPage ? messages.length + 1 : messages.length}
      loadMoreItems={loadMoreItems}
    >
      {({ onItemsRendered, ref }) => (
        <List
          ref={ref}
          height={600}
          itemCount={hasNextPage ? messages.length + 1 : messages.length}
          itemSize={80}
          onItemsRendered={onItemsRendered}
          width="100%"
        >
          {MessageRow}
        </List>
      )}
    </InfiniteLoader>
  );
};

export default ChatMessageList;
```

### 2. Optimized Entity List with Lazy Loading

**EntityList.jsx:**
```jsx
import React, { useState, useCallback, useMemo } from 'react';
import { FixedSizeList as List } from 'react-window';

const EntityList = ({ workspaceId }) => {
  const [entities, setEntities] = useState([]);
  const [selectedEntity, setSelectedEntity] = useState(null);
  const [entityDetails, setEntityDetails] = useState({});

  // Load only essential entity data initially
  const loadEntitySummary = useCallback(async () => {
    const response = await fetch(`/api/workspace/${workspaceId}/entities/summary`);
    const summary = await response.json();
    setEntities(summary.map(entity => ({
      id: entity.id,
      name: entity.name,
      type: entity.type,
      status: entity.status
    })));
  }, [workspaceId]);

  // Load full entity details on demand
  const loadEntityDetails = useCallback(async (entityId) => {
    if (entityDetails[entityId]) return entityDetails[entityId];
    
    const response = await fetch(`/api/entity/${entityId}`);
    const details = await response.json();
    
    setEntityDetails(prev => ({
      ...prev,
      [entityId]: details
    }));
    
    return details;
  }, [entityDetails]);

  const EntityRow = ({ index, style }) => {
    const entity = entities[index];
    
    return (
      <div style={style} className="entity-item">
        <div className="entity-basic">
          <span className="entity-name">{entity.name}</span>
          <span className="entity-type">{entity.type}</span>
          <span className="entity-status">{entity.status}</span>
        </div>
        {selectedEntity === entity.id && (
          <EntityDetails entityId={entity.id} loadDetails={loadEntityDetails} />
        )}
      </div>
    );
  };

  return (
    <div className="entity-list">
      <List
        height={400}
        itemCount={entities.length}
        itemSize={60}
        width="100%"
      >
        {EntityRow}
      </List>
    </div>
  );
};

// Separate component for entity details to prevent unnecessary re-renders
const EntityDetails = React.memo(({ entityId, loadDetails }) => {
  const [details, setDetails] = useState(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const fetchDetails = async () => {
      setLoading(true);
      const entityDetails = await loadDetails(entityId);
      setDetails(entityDetails);
      setLoading(false);
    };
    
    fetchDetails();
  }, [entityId, loadDetails]);

  if (loading) return <div>Loading details...</div>;
  if (!details) return null;

  return (
    <div className="entity-details">
      {/* Render detailed entity information */}
    </div>
  );
});

export default EntityList;
```

### 3. Memory-Efficient State Management

**useWorkspaceData.js:**
```javascript
import { useState, useCallback, useRef } from 'react';

export const useWorkspaceData = (workspaceId) => {
  const [data, setData] = useState({
    entities: [],
    runSessions: [],
    messages: []
  });
  
  const [loading, setLoading] = useState({
    entities: false,
    runSessions: false,
    messages: false
  });
  
  // Use refs to store cache and avoid unnecessary re-renders
  const cache = useRef(new Map());
  const abortControllers = useRef(new Map());

  const fetchWithCache = useCallback(async (key, url) => {
    // Cancel previous request if it exists
    if (abortControllers.current.has(key)) {
      abortControllers.current.get(key).abort();
    }
    
    const abortController = new AbortController();
    abortControllers.current.set(key, abortController);
    
    try {
      const response = await fetch(url, { signal: abortController.signal });
      const result = await response.json();
      
      // Cache the result
      cache.current.set(key, result);
      
      return result;
    } catch (error) {
      if (error.name === 'AbortError') return null;
      throw error;
    } finally {
      abortControllers.current.delete(key);
    }
  }, []);

  const loadEntities = useCallback(async () => {
    setLoading(prev => ({ ...prev, entities: true }));
    try {
      const entities = await fetchWithCache(
        `entities-${workspaceId}`,
        `/api/workspace/${workspaceId}/entities`
      );
      setData(prev => ({ ...prev, entities }));
    } finally {
      setLoading(prev => ({ ...prev, entities: false }));
    }
  }, [workspaceId, fetchWithCache]);

  const loadRunSessions = useCallback(async () => {
    setLoading(prev => ({ ...prev, runSessions: true }));
    try {
      const runSessions = await fetchWithCache(
        `runsessions-${workspaceId}`,
        `/api/workspace/${workspaceId}/runsessions`
      );
      setData(prev => ({ ...prev, runSessions }));
    } finally {
      setLoading(prev => ({ ...prev, runSessions: false }));
    }
  }, [workspaceId, fetchWithCache]);

  // Cleanup function
  const cleanup = useCallback(() => {
    // Abort all pending requests
    abortControllers.current.forEach(controller => controller.abort());
    abortControllers.current.clear();
    
    // Clear cache
    cache.current.clear();
  }, []);

  return {
    data,
    loading,
    loadEntities,
    loadRunSessions,
    cleanup
  };
};
```

### 4. Memory Monitoring Hook

**useMemoryMonitor.js:**
```javascript
import { useEffect, useRef } from 'react';

export const useMemoryMonitor = (thresholdMB = 1000, checkInterval = 30000) => {
  const warningShown = useRef(false);
  const cleanupCallbacks = useRef([]);

  useEffect(() => {
    const checkMemory = () => {
      if ('memory' in performance) {
        const { usedJSHeapSize, totalJSHeapSize } = performance.memory;
        const usageMB = usedJSHeapSize / 1024 / 1024;
        
        console.log(`Memory usage: ${usageMB.toFixed(2)} MB`);
        
        if (usageMB > thresholdMB && !warningShown.current) {
          console.warn(`High memory usage detected: ${usageMB.toFixed(2)} MB`);
          warningShown.current = true;
          
          // Trigger cleanup callbacks
          cleanupCallbacks.current.forEach(callback => callback());
        } else if (usageMB < thresholdMB * 0.8) {
          warningShown.current = false;
        }
      }
    };

    const interval = setInterval(checkMemory, checkInterval);
    
    return () => {
      clearInterval(interval);
      cleanupCallbacks.current = [];
    };
  }, [thresholdMB, checkInterval]);

  const registerCleanup = (callback) => {
    cleanupCallbacks.current.push(callback);
  };

  return { registerCleanup };
};
```

### 5. Optimized Chat Component

**ChatComponent.jsx:**
```jsx
import React, { useState, useCallback, useEffect, useMemo } from 'react';
import ChatMessageList from './ChatMessageList';
import { useMemoryMonitor } from './useMemoryMonitor';

const ChatComponent = ({ workspaceId }) => {
  const [messages, setMessages] = useState([]);
  const [inputValue, setInputValue] = useState('');
  const [isTyping, setIsTyping] = useState(false);
  
  // Memory monitoring
  const { registerCleanup } = useMemoryMonitor(1000);
  
  // Optimize message filtering with useMemo
  const filteredMessages = useMemo(() => {
    return messages.filter(message => 
      message.content.toLowerCase().includes(inputValue.toLowerCase())
    );
  }, [messages, inputValue]);

  // Debounced input handler
  const debouncedSetInput = useCallback(
    debounce((value) => setInputValue(value), 300),
    []
  );

  // Cleanup function for memory management
  const cleanup = useCallback(() => {
    // Clear old messages if too many
    if (messages.length > 1000) {
      setMessages(prev => prev.slice(-500));
    }
    
    // Clear input
    setInputValue('');
  }, [messages.length]);

  // Register cleanup with memory monitor
  useEffect(() => {
    registerCleanup(cleanup);
  }, [registerCleanup, cleanup]);

  const handleSendMessage = useCallback(async (content) => {
    if (!content.trim()) return;
    
    setIsTyping(true);
    try {
      const response = await fetch(`/api/workspace/${workspaceId}/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content })
      });
      
      const newMessage = await response.json();
      setMessages(prev => [...prev, newMessage]);
    } catch (error) {
      console.error('Failed to send message:', error);
    } finally {
      setIsTyping(false);
    }
  }, [workspaceId]);

  return (
    <div className="chat-component">
      <ChatMessageList 
        workspaceId={workspaceId}
        messages={filteredMessages}
      />
      <div className="chat-input">
        <input
          type="text"
          placeholder="Type a message..."
          onChange={(e) => debouncedSetInput(e.target.value)}
        />
        <button 
          onClick={() => handleSendMessage(inputValue)}
          disabled={isTyping}
        >
          {isTyping ? 'Sending...' : 'Send'}
        </button>
      </div>
    </div>
  );
};

// Debounce utility function
function debounce(func, wait) {
  let timeout;
  return function executedFunction(...args) {
    const later = () => {
      clearTimeout(timeout);
      func(...args);
    };
    clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

export default ChatComponent;
```

## CSS for Virtual Scrolling

**styles.css:**
```css
.message-item {
  padding: 10px;
  border-bottom: 1px solid #eee;
  background: white;
}

.message-loading {
  padding: 10px;
  text-align: center;
  color: #666;
  background: #f9f9f9;
}

.entity-item {
  padding: 8px;
  border-bottom: 1px solid #eee;
  background: white;
}

.entity-basic {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.entity-name {
  font-weight: bold;
}

.entity-type {
  color: #666;
  font-size: 0.9em;
}

.entity-status {
  padding: 2px 6px;
  border-radius: 3px;
  font-size: 0.8em;
}

.entity-details {
  margin-top: 8px;
  padding: 8px;
  background: #f5f5f5;
  border-radius: 4px;
}
```

## Implementation Checklist

- [ ] Install `react-window` and `react-window-infinite-loader`
- [ ] Implement virtual scrolling for chat messages
- [ ] Add pagination to entity and runsession lists
- [ ] Implement memory monitoring hook
- [ ] Add proper cleanup in useEffect hooks
- [ ] Use React.memo for expensive components
- [ ] Implement debounced input handlers
- [ ] Add memory usage alerts
- [ ] Test with large datasets
- [ ] Monitor performance improvements

## Testing Memory Usage

1. Open Chrome DevTools
2. Go to Memory tab
3. Take heap snapshot before loading data
4. Load workspace with many entities/runsessions
5. Take another heap snapshot
6. Compare snapshots to identify memory leaks
7. Use Performance tab to monitor memory usage over time